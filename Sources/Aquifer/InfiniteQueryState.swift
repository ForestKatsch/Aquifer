/// What's known about an ``InfiniteQuery`` right now. `pages` is sticky like ``QueryState/value`` —
/// it survives a refetch, so old pages stay on screen while new ones load.
///
/// Read on the main actor; not `Sendable` (`error` is `any Error`).
public struct InfiniteQueryState<Page> {
    public var pages: [Page]
    public var error: Error?

    /// A first load or a full refetch of every loaded page is in flight.
    public var isFetching: Bool
    /// ``InfiniteQueryHandle/fetchNextPage()`` is in flight.
    public var isFetchingNextPage: Bool
    /// ``InfiniteQueryHandle/fetchPreviousPage()`` is in flight.
    public var isFetchingPreviousPage: Bool

    /// There is another page after the last one. Computed from the query's cursor functions.
    public var hasNextPage: Bool
    /// There is another page before the first one.
    public var hasPreviousPage: Bool

    public init(
        pages: [Page] = [],
        error: Error? = nil,
        isFetching: Bool = false,
        isFetchingNextPage: Bool = false,
        isFetchingPreviousPage: Bool = false,
        hasNextPage: Bool = false,
        hasPreviousPage: Bool = false
    ) {
        self.pages = pages
        self.error = error
        self.isFetching = isFetching
        self.isFetchingNextPage = isFetchingNextPage
        self.isFetchingPreviousPage = isFetchingPreviousPage
        self.hasNextPage = hasNextPage
        self.hasPreviousPage = hasPreviousPage
    }
}
