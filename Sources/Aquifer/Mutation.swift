/// A one-shot side effect — create, update, delete. Triggered imperatively with ``Mutate``, not
/// cached or keyed. Refresh affected queries in ``onSuccess(_:_:)``.
public protocol Mutation: Sendable {
    /// `Void` for a mutation that takes no input.
    associatedtype Variables: Sendable
    associatedtype Value: Sendable

    func mutate(_ variables: Variables) async throws -> Value

    /// Runs after a successful ``mutate(_:)``, with the client to invalidate or update queries.
    /// Defaults to nothing.
    func onSuccess(_ value: Value, _ client: QueryClient) async
}

public extension Mutation {
    func onSuccess(_ value: Value, _ client: QueryClient) async {}
}
