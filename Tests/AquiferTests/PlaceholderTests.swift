import Testing
@testable import Aquifer

/// Takes long enough that a test can look at the state before the first fetch lands. Fails while
/// its `Server` is `failing`.
private struct SlowItem: Query {
    var server: String
    var id: String

    func fetch() async throws -> String {
        let s = server, i = id
        _ = await MainActor.run { Server.named(s).logRequest("slow/\(i)", delay: nil) }
        try await Task.sleep(for: .milliseconds(100))
        let failing = await MainActor.run { Server.named(s).failing }
        if failing { throw ProbeError.boom }
        return "body-\(i)"
    }
}

/// `@Fetch` reads `observer.state.withPlaceholder(placeholder)`; these drive the observer directly
/// and apply the placeholder the same way.
@MainActor
@Suite("Placeholder data")
struct PlaceholderTests {
    @Test("the placeholder is shown before the first fetch lands")
    func shownBeforeFetch() async {
        let server = Server()
        let client = QueryClient()
        let observer = QueryObserver<SlowItem>()
        observer.start(SlowItem(server: server.id, id: "a"), client: client)
        await waitUntil { observer.state.isFetching }

        let state = observer.state.withPlaceholder("partial")
        #expect(state.value == "partial")
        #expect(state.isPlaceholder)
        #expect(state.isFetching)
    }

    @Test("the fetched value replaces the placeholder")
    func replacedByFetch() async {
        let server = Server()
        let client = QueryClient()
        let observer = QueryObserver<SlowItem>()
        observer.start(SlowItem(server: server.id, id: "a"), client: client)
        await waitUntil { observer.state.value != nil }

        let state = observer.state.withPlaceholder("partial")
        #expect(state.value == "body-a")
        #expect(state.isPlaceholder == false)
    }

    @Test("the placeholder is never written to the cache or seen by other observers")
    func notCached() async {
        let server = Server()
        let client = QueryClient()
        let query = SlowItem(server: server.id, id: "a")
        let withPlaceholder = QueryObserver<SlowItem>()
        let plain = QueryObserver<SlowItem>()
        withPlaceholder.start(query, client: client)
        plain.start(query, client: client)
        await waitUntil { withPlaceholder.state.isFetching && plain.state.isFetching }

        #expect(withPlaceholder.state.withPlaceholder("partial").value == "partial")
        #expect(plain.state.value == nil)
        #expect(plain.state.isPlaceholder == false)
        #expect(await client.cachedValue(for: query).value == nil)
    }

    @Test("a cached value beats the placeholder")
    func cachedWins() async throws {
        let server = Server()
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(60)))
        let query = SlowItem(server: server.id, id: "a")
        _ = try await client.fetch(query)

        let observer = QueryObserver<SlowItem>()
        observer.start(query, client: client)
        await waitUntil { observer.state.value != nil }

        let state = observer.state.withPlaceholder("partial")
        #expect(state.value == "body-a")
        #expect(state.isPlaceholder == false)
        #expect(server.requestCount == 1, "fresh cache: no second fetch")
    }

    @Test("a failed first fetch keeps the placeholder alongside the error")
    func errorKeepsPlaceholder() async {
        let server = Server()
        server.failing = true
        let client = QueryClient(options: QueryOptions(retry: 0))
        let observer = QueryObserver<SlowItem>()
        observer.start(SlowItem(server: server.id, id: "a"), client: client)
        await waitUntil { observer.state.isError }

        let state = observer.state.withPlaceholder("partial")
        #expect(state.value == "partial")
        #expect(state.isPlaceholder)
        #expect(state.isError)
        #expect(state.error is ProbeError)
    }
}
