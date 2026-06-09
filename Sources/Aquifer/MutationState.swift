/// A mutation's progress. Same three facts as ``QueryState``, named for the verb. Read on the main
/// actor; not `Sendable` (`error` is `any Error`).
public struct MutationState<Value> {
    public var value: Value?
    public var error: Error?
    public var isRunning: Bool

    public init(value: Value? = nil, error: Error? = nil, isRunning: Bool = false) {
        self.value = value
        self.error = error
        self.isRunning = isRunning
    }
}
