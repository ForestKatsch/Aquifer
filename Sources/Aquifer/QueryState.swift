/// What's known about a query right now. `value` is sticky — it survives a refetch, so
/// `value != nil && isFetching` is the stale-while-revalidate case: old data on screen, new loading.
///
/// Read on the main actor; not `Sendable` (`error` is `any Error`).
public struct QueryState<Value> {
    /// The last success — or, before there is one, the view's placeholder (see ``isPlaceholder``).
    public var value: Value?
    public var error: Error?
    public var isFetching: Bool

    /// The last attempt failed. The sticky `value` (if any) is still shown. `error` carries the why.
    public var isError: Bool

    /// Consecutive failures since the last success. Compare against the query's retry budget to tell
    /// "failed — retrying…" from a terminal error.
    public var failureCount: Int

    /// `value` is the placeholder passed to `@Fetch(_:placeholder:)` / `QueryView(_:placeholder:)`,
    /// not data from the query. It flips to `false` as soon as a real value — fetched or already
    /// cached — is available. A placeholder is local to the view that supplied it: it is never
    /// written to the cache, and other observers of the same query never see it.
    ///
    /// If the fetch fails before any real value exists, the placeholder stays on screen with
    /// `error`/`isError` set, like any other sticky value.
    public var isPlaceholder: Bool

    public init(
        value: Value? = nil,
        error: Error? = nil,
        isFetching: Bool = false,
        isError: Bool = false,
        failureCount: Int = 0,
        isPlaceholder: Bool = false
    ) {
        self.value = value
        self.error = error
        self.isFetching = isFetching
        self.isError = isError
        self.failureCount = failureCount
        self.isPlaceholder = isPlaceholder
    }

    /// This state as a view that supplied `placeholder` sees it: the placeholder fills in only
    /// while there is no real value. Applied at read time, so it never reaches the observer or cache.
    func withPlaceholder(_ placeholder: Value?) -> QueryState {
        guard value == nil, let placeholder else { return self }
        var state = self
        state.value = placeholder
        state.isPlaceholder = true
        return state
    }
}
