import SwiftUI

/// Reads one or more queries into a view. One query gives a value; several give a tuple, present
/// only when all succeed.
@MainActor
@propertyWrapper
public struct Fetch<each Q: Query>: @MainActor DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var observer = MultiQueryObserver<repeat each Q>()
    private let queries: (repeat each Q)

    public init(_ queries: repeat each Q) {
        self.queries = (repeat each queries)
    }

    public var wrappedValue: QueryState<(repeat (each Q).Value)> {
        observer.state
    }

    public func update() {
        guard let client else {
            fatalError(
                "No QueryClient in the environment. Inject one at your app root with .queryClient(_:)."
            )
        }
        observer.start(repeat each queries, client: client)
        observer.handleScenePhase(scenePhase)
    }
}
