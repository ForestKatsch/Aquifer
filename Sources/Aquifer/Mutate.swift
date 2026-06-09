import SwiftUI

/// A view's handle on a mutation: call it to run, read it for state.
@MainActor
public struct MutationHandle<M: Mutation> {
    let observer: MutationObserver<M>

    /// Run the mutation. Returns the value or throws; either way ``state`` updates for the view.
    @discardableResult
    public func callAsFunction(_ variables: M.Variables) async throws -> M.Value {
        try await observer.run(variables)
    }

    public var state: MutationState<M.Value> { observer.state }
    public var value: M.Value? { observer.state.value }
    public var error: Error? { observer.state.error }
    public var isRunning: Bool { observer.state.isRunning }
}

public extension MutationHandle where M.Variables == Void {
    @discardableResult
    func callAsFunction() async throws -> M.Value {
        try await observer.run(())
    }
}

/// Reads a mutation into a view as a callable, observable ``MutationHandle``.
@MainActor
@propertyWrapper
public struct Mutate<M: Mutation>: @MainActor DynamicProperty {
    @Environment(\.queryClient) private var client
    @State private var observer = MutationObserver<M>()
    private let mutation: M

    public init(_ mutation: M) {
        self.mutation = mutation
    }

    public var wrappedValue: MutationHandle<M> {
        MutationHandle(observer: observer)
    }

    public func update() {
        guard let client else {
            fatalError(
                "No QueryClient in the environment. Inject one at your app root with .queryClient(_:)."
            )
        }
        observer.configure(mutation, client: client)
    }
}
