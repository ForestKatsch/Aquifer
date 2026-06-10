import Testing
@testable import Aquifer

private struct Boom: Error {}

/// Always fails. A huge `retryDelay` keeps the backoff window open for the whole test, so
/// `shouldFetch` stays `false` for reasons of *time*, letting us assert the backoff gate distinctly
/// from the terminal cap.
private struct AlwaysFails: Query {
    let id: Int
    @MainActor static var attempts = 0
    var retry: Int? { 3 }
    var retryDelay: Duration? { .seconds(1000) }

    func fetch() async throws -> Int {
        await MainActor.run { AlwaysFails.attempts += 1 }
        throw Boom()
    }
}

/// Fails the first two attempts, then succeeds. Tiny `retryDelay` so the backoff window elapses
/// within a short sleep.
private struct FailsTwice: Query {
    @MainActor static var attempts = 0
    var retry: Int? { 5 }
    var retryDelay: Duration? { .milliseconds(2) }

    func fetch() async throws -> Int {
        let n = await MainActor.run { FailsTwice.attempts += 1; return FailsTwice.attempts }
        if n <= 2 { throw Boom() }
        return 99
    }
}

/// Succeeds, then can be flipped to fail — to check the last-good value stays sticky across a failure.
private struct Flips: Query {
    let id: Int
    @MainActor static var failing = false
    var retry: Int? { 3 }
    var retryDelay: Duration? { .seconds(1000) }

    func fetch() async throws -> Int {
        let failing = await MainActor.run { Flips.failing }
        if failing { throw Boom() }
        return id * 10
    }
}

@MainActor
@Suite("Retry & failure state", .serialized)
struct RetryStateTests {
    init() {
        AlwaysFails.attempts = 0
        FailsTwice.attempts = 0
        Flips.failing = false
    }

    @Test("a failure is recorded on the entry, not discarded")
    func recordsFailure() async throws {
        let client = QueryClient()
        _ = try? await client.fetch(AlwaysFails(id: 1))

        let cached = await client.cachedValue(for: AlwaysFails(id: 1))
        #expect(cached.failureCount == 1)
        #expect(cached.isError == true)
        await #expect(throws: Boom.self) { try await client.surfaceError(for: AlwaysFails(id: 1)) }
    }

    @Test("a failed key is not treated as cold — no immediate refetch (the storm fix)")
    func noStorm() async throws {
        let client = QueryClient()
        _ = try? await client.fetch(AlwaysFails(id: 1))
        // Within the backoff window, shouldFetch must be false even though there's no value.
        #expect(await client.shouldFetch(for: AlwaysFails(id: 1)) == false)
        #expect(await client.cachedValue(for: AlwaysFails(id: 1)).value == nil)
    }

    @Test("retries are capped, then the query rests terminally")
    func terminalAfterCap() async throws {
        let client = QueryClient()
        _ = try? await client.fetch(AlwaysFails(id: 2))   // 1
        _ = try? await client.fetch(AlwaysFails(id: 2))   // 2
        _ = try? await client.fetch(AlwaysFails(id: 2))   // 3 == retry cap

        #expect(await client.cachedValue(for: AlwaysFails(id: 2)).failureCount == 3)
        // Terminal: false regardless of elapsed time (cap, not backoff).
        #expect(await client.shouldFetch(for: AlwaysFails(id: 2)) == false)
    }

    @Test("shouldFetch opens again once the backoff has elapsed")
    func backoffElapses() async throws {
        let client = QueryClient()
        _ = try? await client.fetch(FailsTwice())   // fail 1, backoff ~2ms
        #expect(await client.shouldFetch(for: FailsTwice()) == false)   // immediately: still backing off

        try await Task.sleep(for: .milliseconds(20))
        #expect(await client.shouldFetch(for: FailsTwice()) == true)    // after backoff
    }

    @Test("a success after failures clears the error state")
    func recoversOnSuccess() async throws {
        let client = QueryClient()
        _ = try? await client.fetch(FailsTwice())          // fail 1
        try await Task.sleep(for: .milliseconds(10))
        _ = try? await client.fetch(FailsTwice())          // fail 2
        try await Task.sleep(for: .milliseconds(10))
        let value = try await client.fetch(FailsTwice())   // success
        #expect(value == 99)

        let cached = await client.cachedValue(for: FailsTwice())
        #expect(cached.failureCount == 0)
        #expect(cached.isError == false)
        #expect(cached.value == 99)
    }

    @Test("the last-good value stays sticky across a later failure")
    func stickyValue() async throws {
        let client = QueryClient()
        _ = try await client.fetch(Flips(id: 3))   // success → 30
        Flips.failing = true
        _ = try? await client.fetch(Flips(id: 3))  // now fails

        let cached = await client.cachedValue(for: Flips(id: 3))
        #expect(cached.value == 30)          // old value preserved (SWR)
        #expect(cached.isError == true)
        #expect(cached.failureCount == 1)
    }

    @Test("invalidate clears failure so a terminal query refetches")
    func invalidateRecovers() async throws {
        let client = QueryClient()
        _ = try? await client.fetch(AlwaysFails(id: 4))   // 1
        _ = try? await client.fetch(AlwaysFails(id: 4))   // 2
        _ = try? await client.fetch(AlwaysFails(id: 4))   // 3 terminal
        #expect(await client.shouldFetch(for: AlwaysFails(id: 4)) == false)

        await client.invalidate(AlwaysFails.self)

        let cached = await client.cachedValue(for: AlwaysFails(id: 4))
        #expect(cached.failureCount == 0)
        #expect(cached.isError == false)
        #expect(await client.shouldFetch(for: AlwaysFails(id: 4)) == true)
    }

    @Test("a CancellationError is not counted as a failure")
    func cancellationIsNotFailure() async throws {
        let client = QueryClient()
        _ = try? await client.fetch(Cancels())

        let cached = await client.cachedValue(for: Cancels())
        #expect(cached.failureCount == 0)   // teardown/supersede must not poison the entry
        #expect(cached.isError == false)
    }
}

/// Throws `CancellationError` directly — stands in for a fetch torn down by a superseding load.
private struct Cancels: Query {
    func fetch() async throws -> Int { throw CancellationError() }
}

/// `id == 1` always fails (and schedules a backoff retry); other ids succeed. Used to check that
/// switching an observer to a new query cancels the old query's pending retry.
private struct Switchable: Query {
    let id: Int
    @MainActor static var attempts: [Int: Int] = [:]
    var retry: Int? { 5 }
    var retryDelay: Duration? { .milliseconds(50) }

    func fetch() async throws -> Int {
        await MainActor.run { Switchable.attempts[id, default: 0] += 1 }
        if id == 1 { throw Boom() }
        return id * 10
    }
}

@MainActor
@Suite("Observer retry lifecycle", .serialized)
struct ObserverRetryTests {
    @Test("switching the observer's query cancels the old query's pending retry")
    func switchCancelsRetry() async throws {
        Switchable.attempts = [:]
        let client = QueryClient()
        let observer = QueryObserver<Switchable>()

        observer.start(Switchable(id: 1), client: client)
        try await Task.sleep(for: .milliseconds(20))     // id 1 fails once, schedules a ~50ms retry
        #expect(Switchable.attempts[1] == 1)

        observer.start(Switchable(id: 2), client: client)   // switch before the retry fires
        try await Task.sleep(for: .milliseconds(150))       // well past id 1's backoff

        #expect(Switchable.attempts[1] == 1)   // old retry was cancelled — no second attempt
        #expect(observer.state.value == 20)    // state reflects the new query
    }
}
