/// What's known about a query right now. `value` is sticky — it survives a refetch, so
/// `value != nil && isFetching` is the stale-while-revalidate case: old data on screen, new loading.
///
/// Read on the main actor; not `Sendable` (`error` is `any Error`).
public struct QueryState<Value> {
    public var value: Value?
    public var error: Error?
    public var isFetching: Bool

    /// The last attempt failed. The sticky `value` (if any) is still shown. `error` carries the why.
    public var isError: Bool

    /// Consecutive failures since the last success. Compare against the query's retry budget to tell
    /// "failed — retrying…" from a terminal error.
    public var failureCount: Int

    public init(
        value: Value? = nil,
        error: Error? = nil,
        isFetching: Bool = false,
        isError: Bool = false,
        failureCount: Int = 0
    ) {
        self.value = value
        self.error = error
        self.isFetching = isFetching
        self.isError = isError
        self.failureCount = failureCount
    }
}
