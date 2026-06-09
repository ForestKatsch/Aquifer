import SwiftUI

/// Reads a query into a view as its ``QueryState``. The first read starts the fetch; the value is
/// kept across refetches.
///
/// ```swift
/// struct TodoDetail: View {
///     @Fetch(TodoByID(id: 5)) private var todo
///
///     var body: some View {
///         if let todo = todo.value { TodoCard(todo) }
///         if todo.isFetching { RefreshDot() }
///         if let error = todo.error { ErrorBanner(error) }
///     }
/// }
/// ```
///
/// For the uncommon case of several queries resolved as one unit, use ``FetchMultiple``.
@MainActor
@propertyWrapper
public struct Fetch<Q: Query>: @MainActor DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var observer = QueryObserver<Q>()
    private let query: Q

    public init(_ query: Q) {
        self.query = query
    }

    public var wrappedValue: QueryState<Q.Value> {
        observer.state
    }

    public func update() {
        guard let client else {
            fatalError(
                "No QueryClient in the environment. Inject one at your app root with .queryClient(_:)."
            )
        }
        observer.start(query, client: client)
        observer.handleScenePhase(scenePhase)
    }
}
