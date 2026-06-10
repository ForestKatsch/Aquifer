import Testing
@testable import Aquifer

private struct Counter: Query {
    let id: Int
    @MainActor static var fetchCount = 0

    func fetch() async throws -> Int {
        await MainActor.run { Counter.fetchCount += 1 }
        return id * 10
    }
}

@MainActor
@Suite("QueryClient", .serialized)
struct QueryClientTests {
    init() { Counter.fetchCount = 0 }

    @Test("fetch stores and returns the value")
    func fetchStores() async throws {
        let client = QueryClient()
        let value = try await client.fetch(Counter(id: 5))
        #expect(value == 50)

        let cached = await client.cachedValue(for: Counter(id: 5))
        #expect(cached.value == 50)
        #expect(cached.isStale == false)
    }

    @Test("identical concurrent fetches are deduplicated")
    func dedup() async throws {
        let client = QueryClient()
        async let a = client.fetch(Counter(id: 1))
        async let b = client.fetch(Counter(id: 1))
        _ = try await (a, b)
        #expect(Counter.fetchCount == 1)
    }

    @Test("invalidate marks the value stale but keeps it")
    func invalidate() async throws {
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(1000)))
        _ = try await client.fetch(Counter(id: 2))
        #expect(await client.cachedValue(for: Counter(id: 2)).isStale == false)

        await client.invalidate(Counter.self)

        let cached = await client.cachedValue(for: Counter(id: 2))
        #expect(cached.value == 20)
        #expect(cached.isStale == true)
    }

    @Test("forceStaleKeepingValue keeps the value and forces the next fetch")
    func forceStaleKeepsValue() async throws {
        // Backs an explicit refetch(): even a fresh, successful entry must refetch ("no matter
        // what") while keeping its value on screen ("don't delete the data").
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(1000)))
        _ = try await client.fetch(Counter(id: 7))
        #expect(await client.cachedValue(for: Counter(id: 7)).isStale == false)

        await client.forceStaleKeepingValue(for: Counter(id: 7))

        let cached = await client.cachedValue(for: Counter(id: 7))
        #expect(cached.value == 70) // value kept (stale-while-revalidate)
        #expect(cached.isStale == true) // and forced stale…
        #expect(await client.shouldFetch(for: Counter(id: 7)) == true) // …so the next load refetches
    }

    @Test("remove drops the value entirely")
    func remove() async throws {
        let client = QueryClient()
        _ = try await client.fetch(Counter(id: 3))
        await client.remove(Counter.self)
        #expect(await client.cachedValue(for: Counter(id: 3)).value == nil)
    }

    @Test("predicate invalidation only touches matches")
    func predicate() async throws {
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(1000)))
        _ = try await client.fetch(Counter(id: 1))
        _ = try await client.fetch(Counter(id: 2))

        await client.invalidate { (q: Counter) in q.id == 1 }

        #expect(await client.cachedValue(for: Counter(id: 1)).isStale == true)
        #expect(await client.cachedValue(for: Counter(id: 2)).isStale == false)
    }
}
