import Testing
@testable import Aquifer

/// A paged source of integers. Page `n` holds `[n*10, n*10+1, n*10+2]`. The cursor is the page
/// index; `nil` past `lastPage` signals the end.
private struct Numbers: InfiniteQuery {
    let lastPage: Int
    @MainActor static var fetchCount = 0

    var initialPageParam: Int { 0 }

    func fetch(page param: Int) async throws -> [Int] {
        await MainActor.run { Numbers.fetchCount += 1 }
        return [param * 10, param * 10 + 1, param * 10 + 2]
    }

    func nextPageParam(after last: [Int], pages: [[Int]], params: [Int]) -> Int? {
        let current = params.count - 1
        return current < lastPage ? current + 1 : nil
    }

    func previousPageParam(before first: [Int], pages: [[Int]], params: [Int]) -> Int? {
        let firstParam = params.first ?? 0
        return firstParam > 0 ? firstParam - 1 : nil
    }
}

/// Starts at page 2 so it has pages on both sides — exercises `fetchPreviousPage`.
private struct Window: InfiniteQuery {
    var initialPageParam: Int { 2 }

    func fetch(page param: Int) async throws -> Int { param }

    func nextPageParam(after last: Int, pages: [Int], params: [Int]) -> Int? {
        let last = params[params.count - 1]
        return last < 4 ? last + 1 : nil
    }

    func previousPageParam(before first: Int, pages: [Int], params: [Int]) -> Int? {
        let first = params[0]
        return first > 0 ? first - 1 : nil
    }
}

/// A cursor that is `nil` for the first request — the null-first pattern.
private struct Cursored: InfiniteQuery {
    var initialPageParam: String? { nil }

    func fetch(page cursor: String?) async throws -> String {
        cursor ?? "first"
    }

    func nextPageParam(after last: String, pages: [String], params: [String?]) -> String?? {
        // Two pages total: first (nil) -> "p1", then stop.
        guard params.count == 1 else { return nil }
        return "p1"
    }
}

@MainActor
@Suite("InfiniteQuery", .serialized)
struct InfiniteQueryTests {
    init() { Numbers.fetchCount = 0 }

    @Test("initial load fetches just the first page")
    func initialLoad() async throws {
        let client = QueryClient()
        let value = try await client.fetchInfinite(Numbers(lastPage: 5))
        #expect(value.pages == [[0, 1, 2]])
        #expect(value.params == [0])
        #expect(Numbers.fetchCount == 1)
    }

    @Test("fetchNextPage appends the following page")
    func nextPageAppends() async throws {
        let client = QueryClient()
        _ = try await client.fetchInfinite(Numbers(lastPage: 5))
        let value = try await client.fetchNextPage(Numbers(lastPage: 5))
        #expect(value.pages == [[0, 1, 2], [10, 11, 12]])
        #expect(value.params == [0, 1])
    }

    @Test("fetchNextPage stops at the last page")
    func nextPageStops() async throws {
        let client = QueryClient()
        _ = try await client.fetchInfinite(Numbers(lastPage: 1))
        _ = try await client.fetchNextPage(Numbers(lastPage: 1))   // loads page 1, the last
        let again = try await client.fetchNextPage(Numbers(lastPage: 1))
        #expect(again.pages.count == 2)   // no third page
    }

    @Test("fetchPreviousPage prepends the earlier page")
    func previousPagePrepends() async throws {
        let client = QueryClient()
        let first = try await client.fetchInfinite(Window())   // page 2
        #expect(first.pages == [2])

        let value = try await client.fetchPreviousPage(Window())   // prepend page 1
        #expect(value.pages == [1, 2])
        #expect(value.params == [1, 2])

        let again = try await client.fetchPreviousPage(Window())   // prepend page 0
        #expect(again.pages == [0, 1, 2])

        let stopped = try await client.fetchPreviousPage(Window())   // no page before 0
        #expect(stopped.pages == [0, 1, 2])
    }

    @Test("invalidate refetches every loaded page, in order")
    func refetchAll() async throws {
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(1000)))
        _ = try await client.fetchInfinite(Numbers(lastPage: 5))
        _ = try await client.fetchNextPage(Numbers(lastPage: 5))
        #expect(Numbers.fetchCount == 2)

        await client.invalidate(Numbers.self)
        #expect(await client.cachedPages(for: Numbers(lastPage: 5)).isStale == true)

        let value = try await client.fetchInfinite(Numbers(lastPage: 5))
        #expect(value.pages == [[0, 1, 2], [10, 11, 12]])   // both pages, same order
        #expect(Numbers.fetchCount == 4)                    // both refetched
    }

    @Test("concurrent next-page requests are deduplicated")
    func dedup() async throws {
        let client = QueryClient()
        _ = try await client.fetchInfinite(Numbers(lastPage: 5))
        Numbers.fetchCount = 0
        async let a = client.fetchNextPage(Numbers(lastPage: 5))
        async let b = client.fetchNextPage(Numbers(lastPage: 5))
        _ = try await (a, b)
        #expect(Numbers.fetchCount == 1)
    }

    @Test("remove drops the loaded pages")
    func remove() async throws {
        let client = QueryClient()
        _ = try await client.fetchInfinite(Numbers(lastPage: 5))
        await client.remove(Numbers.self)
        #expect(await client.cachedPages(for: Numbers(lastPage: 5)).value == nil)
    }

    @Test("a nil first cursor loads, then advances by cursor")
    func nullFirstCursor() async throws {
        let client = QueryClient()
        let first = try await client.fetchInfinite(Cursored())
        #expect(first.pages == ["first"])
        #expect(first.params == [nil])

        let second = try await client.fetchNextPage(Cursored())
        #expect(second.pages == ["first", "p1"])
        #expect(second.params == [nil, "p1"])

        let stopped = try await client.fetchNextPage(Cursored())
        #expect(stopped.pages.count == 2)   // nextPageParam returned nil → no more
    }
}
