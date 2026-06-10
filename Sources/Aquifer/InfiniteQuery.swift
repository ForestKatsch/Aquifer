/// A paginated query. Like ``Query``, its `Hashable` identity is the cache key — but instead of one
/// value it accumulates a list of pages in that one entry. The identity is the query *without* any
/// page cursor; cursors are threaded through ``fetch(page:)`` as pages are loaded.
///
/// `PageParam` is the cursor. It may be optional (e.g. `String?`) so the first request can carry no
/// cursor — use ``initialPageParam`` for that. ``nextPageParam(after:pages:params:)`` returns the
/// cursor for the following page, or `nil` to signal there are no more. When `PageParam` is itself
/// optional, the *outer* `nil` means stop: write `guard let next = last.nextCursor else { return nil
/// }; return next` so "no more pages" stays distinct from "next page has a nil cursor."
public protocol InfiniteQuery: Hashable, Sendable {
    /// `Sendable` so a page can cross the cache's actor boundary.
    associatedtype Page: Sendable
    /// The cursor. `Sendable` to cross the actor; `Hashable` only so it composes cleanly with keys.
    associatedtype PageParam: Hashable & Sendable

    /// The cursor for the very first page. May be `nil` when `PageParam` is optional.
    var initialPageParam: PageParam { get }

    func fetch(page param: PageParam) async throws -> Page

    /// The cursor for the page after `last`, or `nil` if there is none. `pages`/`params` are every
    /// page loaded so far, oldest first, so a server returning offsets or "has more" can decide.
    func nextPageParam(after last: Page, pages: [Page], params: [PageParam]) -> PageParam?

    /// The cursor for the page before `first`, or `nil` (the default) for a forward-only query.
    func previousPageParam(before first: Page, pages: [Page], params: [PageParam]) -> PageParam?

    /// How long the loaded pages stay fresh. `nil` uses the ``QueryClient``'s value.
    var staleTime: Duration? { get }

    /// How long the entry is kept after its last observer leaves. `nil` uses the client's.
    var gcTime: Duration? { get }

    /// How many attempts a page load gets before resting in a terminal error. `nil` uses the client's.
    var retry: Int? { get }

    /// Base delay before the first retry; backs off exponentially. `nil` uses the client's.
    var retryDelay: Duration? { get }
}

extension InfiniteQuery {
    public func previousPageParam(before first: Page, pages: [Page], params: [PageParam]) -> PageParam? { nil }
    public var staleTime: Duration? { nil }
    public var gcTime: Duration? { nil }
    public var retry: Int? { nil }
    public var retryDelay: Duration? { nil }
}

/// The accumulated pages of an ``InfiniteQuery`` plus the cursor each was fetched with. `pages` and
/// `params` stay index-aligned and ordered oldest first. This is what the cache stores for an
/// infinite query, the way a plain ``Query`` stores a single value.
public struct PagedValue<Page: Sendable, PageParam: Sendable>: Sendable {
    public var pages: [Page]
    public var params: [PageParam]

    public init(pages: [Page] = [], params: [PageParam] = []) {
        self.pages = pages
        self.params = params
    }
}
