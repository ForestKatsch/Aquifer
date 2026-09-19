//
//  AquiferRegressionProbes.swift
//
//  Offline reproductions of the "it redownloads / it loses your spot" reports.
//  No network, no simulator: a fake in-memory feed stands in for news.ycombinator.com.
//
//  Every test asserts the behaviour we WANT, so a failing test names a real bug.
//
//  Each test gets its own Server instance, addressed by a UUID carried in the query, so nothing
//  is shared between tests even when the testing library runs them in parallel.
//

import SwiftUI
import Testing
@testable import Aquifer

enum ProbeError: Error { case boom }

/// An in-memory stand-in for the HN listing. Models a feed that shifts (new posts at the top),
/// pages that fail or come back short, and per-page latency.
@MainActor
final class Server {
    private static var registry: [String: Server] = [:]

    let id = UUID().uuidString

    init() { Server.registry[id] = self }
    static func named(_ id: String) -> Server { registry[id]! }

    var feed: [String] = (0 ..< 200).map { "item-\($0)" }
    var pageSize = 3
    var requestLog: [String] = []
    var failing = false
    var truncateAt: Int?
    var delays: [Int: Duration] = [:]

    var requestCount: Int { requestLog.count }

    /// New posts arrive at the top of the feed — exactly what HN does between two page loads.
    func insertAtTop(_ n: Int) {
        feed.insert(contentsOf: (0 ..< n).map { "fresh-\($0)" }, at: 0)
    }

    func logRequest(_ label: String, delay page: Int?) -> Duration? {
        requestLog.append(label)
        return page.flatMap { delays[$0] }
    }

    func page(_ p: Int) throws -> [String] {
        if failing { throw ProbeError.boom }
        if let t = truncateAt, p >= t { return [] }
        let start = p * pageSize
        guard start < feed.count else { return [] }
        return Array(feed[start ..< min(start + pageSize, feed.count)])
    }
}

/// Mirrors Tangerine's `FetchBrowseListing` cursor logic exactly.
struct Feed: InfiniteQuery {
    var server: String
    var name: String = "news"
    var staleTimeOverride: Duration?

    var staleTime: Duration? { staleTimeOverride }
    var initialPageParam: Int { 0 }

    func fetch(page param: Int) async throws -> [String] {
        let s = server
        let delay = await MainActor.run { Server.named(s).logRequest("\(name)/\(param)", delay: param) }
        if let delay { try? await Task.sleep(for: delay) }
        return try await MainActor.run { try Server.named(s).page(param) }
    }

    func nextPageParam(after last: [String], pages _: [[String]], params: [Int]) -> Int? {
        last.isEmpty ? nil : (params.last ?? 0) + 1
    }

    /// The library can't dedupe opaque pages, so it hands the query the accumulated list and lets
    /// it decide. A feed that shifts between two page requests serves the same item on both; this
    /// keeps the first occurrence, which is what an id-keyed `ForEach` needs.
    func reconcile(_ value: PagedValue<[String], Int>) -> PagedValue<[String], Int> {
        var seen = Set<String>()
        return PagedValue(
            pages: value.pages.map { $0.filter { seen.insert($0).inserted } },
            params: value.params
        )
    }
}

/// Mirrors Tangerine's `FetchPost`.
struct Item: Query {
    var server: String
    var id: String
    var staleTimeOverride: Duration?
    var staleTime: Duration? { staleTimeOverride }

    func fetch() async throws -> String {
        let s = server, i = id
        _ = await MainActor.run { Server.named(s).logRequest("item/\(i)", delay: nil) }
        let failing = await MainActor.run { Server.named(s).failing }
        if failing { throw ProbeError.boom }
        return "body-\(i)"
    }
}

@MainActor
func waitUntil(_ timeout: Duration = .milliseconds(800), _ condition: @MainActor () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Let the notify / event-stream machinery run to a standstill.
@MainActor
func quiesce(_ duration: Duration = .milliseconds(150)) async {
    try? await Task.sleep(for: duration)
}

@MainActor
@Suite("Aquifer regression probes")
struct AquiferRegressionProbes {

    // MARK: - 1. Revalidation re-downloads the entire page stack

    /// Scroll three pages deep, then come back to the app.
    @Test("returning to the foreground does not re-download every loaded page")
    func foregroundRefetchesWholeList() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .milliseconds(30)))
        let observer = InfiniteQueryObserver<Feed>()

        observer.start(Feed(server: server.id), client: client)
        await waitUntil { observer.state.pages.count == 1 }
        await observer.fetchNextPage()
        await observer.fetchNextPage()
        #expect(observer.state.pages.count == 3)

        let afterScroll = server.requestCount
        try? await Task.sleep(for: .milliseconds(50))   // let the entry go stale

        observer.handleScenePhase(.active)
        observer.handleScenePhase(.background)
        observer.handleScenePhase(.active)
        await quiesce()

        let requests = server.requestCount - afterScroll
        #expect(requests <= 1, "resuming issued \(requests) requests — the whole page stack was re-downloaded")
    }

    /// Tangerine's real client config, and the most common interaction of all: leave a tab, come
    /// back a few seconds later.
    @Test("revisiting a scrolled tab does not re-download the page stack")
    func tabRevisitRefetchesEverything() async {
        let server = Server()
        // Exactly TangerineApp's QueryClient.
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(5), refetchOnForeground: true))
        let query = Feed(server: server.id, name: "news")

        let first = InfiniteQueryObserver<Feed>()
        first.start(query, client: client)
        await waitUntil { first.state.pages.count == 1 }
        for _ in 0 ..< 4 { await first.fetchNextPage() }   // user scrolls 5 pages deep
        #expect(first.state.pages.count == 5)

        // Tab away: the observer leaves; the entry stays cached (gcTime 300s).
        first.start(Feed(server: server.id, name: "other"), client: client)
        await quiesce(.milliseconds(80))

        // More than staleTime passes while the user reads another tab.
        try? await Task.sleep(for: .seconds(5.1))
        let beforeReturn = server.requestCount

        let second = InfiniteQueryObserver<Feed>()
        second.start(query, client: client)
        await waitUntil(.seconds(2)) { second.state.pages.count >= 5 }
        await quiesce()

        let requests = server.requestCount - beforeReturn
        #expect(requests <= 1, "returning to a 5-page-deep tab issued \(requests) requests")
    }

    /// TabRoot keeps news/show/ask alive at once, and `scenePhase` is an @Environment value, so
    /// every live InfiniteFetch re-renders on resume.
    @Test("resuming the app does not multiply requests across live tabs")
    func multiTabForegroundAmplification() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(5), refetchOnForeground: true))
        var observers: [InfiniteQueryObserver<Feed>] = []

        for name in ["news", "show", "ask"] {
            let o = InfiniteQueryObserver<Feed>()
            o.start(Feed(server: server.id, name: name), client: client)
            await waitUntil { o.state.pages.count == 1 }
            await o.fetchNextPage()
            await o.fetchNextPage()          // each tab 3 pages deep
            observers.append(o)
        }

        try? await Task.sleep(for: .seconds(5.1))
        let before = server.requestCount

        for o in observers {
            o.handleScenePhase(.active)
            o.handleScenePhase(.background)
            o.handleScenePhase(.active)
        }
        await quiesce(.milliseconds(600))

        let requests = server.requestCount - before
        #expect(requests <= 3, "one resume issued \(requests) requests across 3 live tabs")
    }

    // MARK: - 2. A transient interruption counts as a foreground

    /// Control Centre, the app switcher, a permission alert: active → inactive → active, with no
    /// backgrounding at all.
    @Test("a transient inactive phase does not trigger a refetch")
    func transientInactiveRefetches() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .milliseconds(30)))
        let observer = InfiniteQueryObserver<Feed>()

        observer.start(Feed(server: server.id), client: client)
        await waitUntil { observer.state.pages.count == 1 }
        await observer.fetchNextPage()

        try? await Task.sleep(for: .milliseconds(50))
        let before = server.requestCount

        observer.handleScenePhase(.active)
        observer.handleScenePhase(.inactive)   // swipe down Control Centre
        observer.handleScenePhase(.active)     // dismiss it
        await quiesce()

        let requests = server.requestCount - before
        #expect(requests == 0, "a transient .inactive → .active triggered \(requests) requests")
    }

    // MARK: - 3. The refetch moves the ground under the user

    /// The user is on page 3. A refetch runs and the second page comes back empty (HN hiccup,
    /// rate-limit page, end-of-feed drift).
    @Test("a short page during a refetch does not truncate the list under the user")
    func refetchTruncatesList() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .milliseconds(30)))
        let observer = InfiniteQueryObserver<Feed>()

        observer.start(Feed(server: server.id), client: client)
        await waitUntil { observer.state.pages.count == 1 }
        await observer.fetchNextPage()
        await observer.fetchNextPage()
        let rowsBefore = observer.state.pages.flatMap { $0 }.count
        #expect(rowsBefore == 9)

        server.truncateAt = 1   // page 1 now comes back empty
        try? await Task.sleep(for: .milliseconds(50))
        await observer.refetch()
        await quiesce()

        let rowsAfter = observer.state.pages.flatMap { $0 }.count
        #expect(rowsAfter >= rowsBefore,
                "the list collapsed from \(rowsBefore) rows to \(rowsAfter) — the user is thrown back to the top")
        #expect(observer.state.hasNextPage,
                "hasNextPage went false, so the list can no longer be scrolled back to where the user was")
    }

    /// Does a refetch disturb the rows the List is anchored to?
    @Test("a refetch leaves the anchored row where it was")
    func refetchKeepsRowIdentity() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .milliseconds(30)))
        let o = InfiniteQueryObserver<Feed>()
        o.start(Feed(server: server.id), client: client)
        await waitUntil { o.state.pages.count == 1 }
        await o.fetchNextPage()
        await o.fetchNextPage()
        let before = o.state.pages.flatMap { $0 }

        server.insertAtTop(2)          // two new posts, as HN does constantly
        try? await Task.sleep(for: .milliseconds(50))
        await o.refetch()
        await quiesce()
        let after = o.state.pages.flatMap { $0 }

        let anchor = before[6]         // the row the user was looking at
        #expect(after.firstIndex(of: anchor) == 6,
                "the post the user was reading (\(anchor)) moved from row 6 to \(String(describing: after.firstIndex(of: anchor)))")
    }

    /// THE classic infinite-scroll duplicate: the user keeps scrolling while the feed shifts.
    /// Page 3 is fetched by *index* against a feed that has moved on, so it overlaps page 2.
    @Test("scrolling while the feed shifts does not produce duplicate rows")
    func nextPageAfterShiftDuplicates() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(60)))
        let observer = InfiniteQueryObserver<Feed>()

        observer.start(Feed(server: server.id), client: client)
        await waitUntil { observer.state.pages.count == 1 }
        await observer.fetchNextPage()
        await observer.fetchNextPage()          // 3 pages: item-0 … item-8

        server.insertAtTop(1)                   // one new post lands on HN
        await observer.fetchNextPage()          // user scrolls on → asks for page 3

        let rows = observer.state.pages.flatMap { $0 }
        let dupes = Dictionary(grouping: rows, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(dupes.isEmpty, "duplicate ids after scrolling across a feed shift: \(dupes) — rows: \(rows)")
    }

    // MARK: - 4. Races and lifecycle

    /// Foreground refetch is in flight; the user scrolls and the last row asks for the next page.
    @Test("a next-page load concurrent with a refetch is not clobbered")
    func concurrentNextPageAndRefetch() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .milliseconds(30)))
        let observer = InfiniteQueryObserver<Feed>()

        observer.start(Feed(server: server.id), client: client)
        await waitUntil { observer.state.pages.count == 1 }
        await observer.fetchNextPage()
        #expect(observer.state.pages.count == 2)

        // Make the full refetch slow so a scroll can land in the middle of it.
        server.delays = [0: .milliseconds(120), 1: .milliseconds(120)]
        try? await Task.sleep(for: .milliseconds(50))

        async let refetch: Void = observer.refetch()
        try? await Task.sleep(for: .milliseconds(20))
        async let next: Void = observer.fetchNextPage()
        _ = await (refetch, next)
        await quiesce(.milliseconds(400))

        #expect(observer.state.pages.count == 3,
                "after a refetch raced a next-page load the list has \(observer.state.pages.count) pages, not 3 — one write clobbered the other")
    }

    /// `staleTime: .zero` is the obvious way to spell "always revalidate".
    @Test("staleTime .zero settles instead of looping forever")
    func staleTimeZeroLoops() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .zero))
        let observer = QueryObserver<Item>()

        observer.start(Item(server: server.id, id: "a"), client: client)
        await waitUntil { observer.state.value != nil }
        try? await Task.sleep(for: .milliseconds(200))

        #expect(server.requestCount < 10,
                "one mount issued \(server.requestCount) requests in 200ms — each success notifies the observer, which immediately refetches")
    }

    /// The view is dismissed while its very first fetch is still in flight.
    @Test("an entry created after its last observer left is still garbage-collected")
    func gcMissesInFlightEntry() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(60), gcTime: .milliseconds(50)))
        let query = Item(server: server.id, id: "orphan")
        let key = CacheKey(query)

        await client.retain(key)
        let fetching = Task { try? await client.fetch(query) }
        await client.release(key)               // released before the fetch resolves
        _ = await fetching.value

        #expect(await client.cachedValue(for: query).value == "body-orphan", "sanity: the fetch did store an entry")

        try? await Task.sleep(for: .milliseconds(250))   // 5x gcTime, zero observers
        let later = await client.cachedValue(for: query)
        #expect(later.value == nil,
                "entry still cached (\(String(describing: later.value))) long after gcTime with zero observers")
    }

    // MARK: - 5. Controls that should still hold

    @Test("a fresh cached value is not refetched on foreground")
    func freshValueForeground() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(60)))
        let observer = QueryObserver<Item>()
        observer.start(Item(server: server.id, id: "p1"), client: client)
        await waitUntil { observer.state.value != nil }

        let before = server.requestCount
        observer.handleScenePhase(.active)
        observer.handleScenePhase(.background)
        observer.handleScenePhase(.active)
        await quiesce()
        #expect(server.requestCount - before == 0)
    }

    @Test("two observers of one key do not double-load on foreground")
    func twoObserversForeground() async {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .milliseconds(30)))
        let a = InfiniteQueryObserver<Feed>()
        let b = InfiniteQueryObserver<Feed>()
        a.start(Feed(server: server.id), client: client)
        b.start(Feed(server: server.id), client: client)
        await waitUntil { a.state.pages.count == 1 && b.state.pages.count == 1 }

        try? await Task.sleep(for: .milliseconds(50))
        let before = server.requestCount
        for o in [a, b] {
            o.handleScenePhase(.active)
            o.handleScenePhase(.background)
            o.handleScenePhase(.active)
        }
        await quiesce(.milliseconds(250))
        let requests = server.requestCount - before
        #expect(requests <= 1, "two observers of one key issued \(requests) foreground requests")
    }
}
