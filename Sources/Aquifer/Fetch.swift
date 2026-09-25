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
/// Pass a `placeholder` to show something while the first fetch is in flight — typically the partial
/// value a list row already had. It's shown only until real data arrives, flagged by
/// ``QueryState/isPlaceholder``, and never cached:
///
/// ```swift
/// @Fetch(TodoByID(id: summary.id), placeholder: Todo(summary: summary)) private var todo
/// ```
///
/// The `$`-projection of ``Fetch``: imperative actions on the query.
@MainActor
public struct FetchActions<Q: Query> {
    let observer: QueryObserver<Q>

    /// Force a fresh fetch, clearing any terminal error — a Retry button.
    public func refetch() { observer.refetch() }

    /// Awaitable form for `.refreshable { await $todo.refetch() }`: the spinner stays until the
    /// fetch actually finishes.
    public func refetch() async { await observer.refetch() }
}

/// For the uncommon case of several queries resolved as one unit, use ``FetchMultiple``.
@MainActor
@propertyWrapper
public struct Fetch<Q: Query>: @MainActor DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var observer = QueryObserver<Q>()
    private let query: Q
    private let placeholder: Q.Value?

    /// - Parameter placeholder: Shown as `value` (with `isPlaceholder == true`) until the query has
    ///   a real value. Local to this view; never written to the cache.
    public init(_ query: Q, placeholder: Q.Value? = nil) {
        self.query = query
        self.placeholder = placeholder
    }

    public var wrappedValue: QueryState<Q.Value> {
        observer.state.withPlaceholder(placeholder)
    }

    /// Actions on the query, via the `$`-projection: `$todo.refetch()` for pull-to-refresh / Retry.
    public var projectedValue: FetchActions<Q> {
        FetchActions(observer: observer)
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
