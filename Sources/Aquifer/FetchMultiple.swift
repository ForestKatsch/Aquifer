import SwiftUI

/// Reads several queries into a view as one ``QueryState``. The combined value is present only when
/// every query has succeeded; it's fetching if any is, failed if any failed. Each query stays
/// independently cached and invalidated.
///
/// ```swift
/// struct Profile: View {
///     @FetchMultiple(UserByID(id: 1), PostsByUser(id: 1)) private var data
///
///     var body: some View {
///         if let (user, posts) = data.value { … }
///     }
/// }
/// ```
///
/// For the common single-query case, use ``Fetch`` — it avoids this type's `each Q` parameter pack,
/// which can crash the Swift runtime while building view metadata on current toolchains.
@MainActor
@propertyWrapper
public struct FetchMultiple<each Q: Query>: @MainActor DynamicProperty {
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
