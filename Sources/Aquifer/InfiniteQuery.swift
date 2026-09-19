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

    /// What a *background* revalidation reloads — going stale, returning to the foreground, or an
    /// ``QueryClient/invalidate(_:)-(Q.Type)``. Defaults to ``InfiniteRevalidation/firstPage``.
    var revalidation: InfiniteRevalidation { get }

    /// Reconcile the accumulated pages after a load, before they are cached. A feed that shifts
    /// between two page requests can serve the same item on both, so a list keyed by item identity
    /// sees a duplicate; use this to drop it. Default: unchanged.
    func reconcile(_ value: PagedValue<Page, PageParam>) -> PagedValue<Page, PageParam>

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
    public var revalidation: InfiniteRevalidation { .firstPage }
    public func reconcile(_ value: PagedValue<Page, PageParam>) -> PagedValue<Page, PageParam> { value }
    public var staleTime: Duration? { nil }
    public var gcTime: Duration? { nil }
    public var retry: Int? { nil }
    public var retryDelay: Duration? { nil }
}

/// What a background revalidation of an ``InfiniteQuery`` reloads.
///
/// The distinction only applies to *implicit* reloads — staleness, foregrounding, invalidation.
/// ``QueryClient/fetchNextPage(_:)`` and the page-stepping actions are unaffected.
public enum InfiniteRevalidation: Sendable {
    /// Reload only the first page and leave the pages after it alone. One request, and a reader
    /// scrolled ten pages deep keeps their place. The default.
    case firstPage

    /// Reload every loaded page in order, re-threading cursors from ``InfiniteQuery/initialPageParam``.
    /// Costs one request per loaded page and replaces the whole list, so a reader scrolled deep will
    /// see the list move under them — choose it when cross-page consistency matters more than that.
    case allPages

    /// Don't reload in the background at all; the pages stay as they are until something explicitly
    /// asks for them again. The entry still reads as stale.
    case none
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
