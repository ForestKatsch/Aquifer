/// What's known about a query right now. `value` is sticky — it survives a refetch, so
/// `value != nil && isFetching` is the stale-while-revalidate case: old data on screen, new loading.
///
/// Read on the main actor; not `Sendable` (`error` is `any Error`).
public struct QueryState<Value> {
    public var value: Value?
    public var error: Error?
    public var isFetching: Bool

    public init(value: Value? = nil, error: Error? = nil, isFetching: Bool = false) {
        self.value = value
        self.error = error
        self.isFetching = isFetching
    }
}
