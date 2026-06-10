import SwiftUI

/// A view's handle on an infinite query: read it for state, call its methods to load more. Page
/// loads are idempotent — `fetchNextPage()` is a no-op when there's no next page or one is already
/// loading, so it's safe to call straight from a row's `.onAppear`.
@MainActor
public struct InfiniteQueryHandle<Q: InfiniteQuery> {
    let observer: InfiniteQueryObserver<Q>

    public var state: InfiniteQueryState<Q.Page> { observer.state }
    public var pages: [Q.Page] { observer.state.pages }
    public var error: Error? { observer.state.error }
    public var isFetching: Bool { observer.state.isFetching }
    public var isFetchingNextPage: Bool { observer.state.isFetchingNextPage }
    public var isFetchingPreviousPage: Bool { observer.state.isFetchingPreviousPage }
    public var hasNextPage: Bool { observer.state.hasNextPage }
    public var hasPreviousPage: Bool { observer.state.hasPreviousPage }

    public func fetchNextPage() async { await observer.fetchNextPage() }
    public func fetchPreviousPage() async { await observer.fetchPreviousPage() }

    /// Force a fresh load of the pages, clearing any terminal error — pull-to-refresh, a Retry button.
    public func refetch() { observer.refetch() }
}

/// Reads an ``InfiniteQuery`` into a view as an observable ``InfiniteQueryHandle``. The first page
/// loads automatically; call ``InfiniteQueryHandle/fetchNextPage()`` to grow the list.
@MainActor
@propertyWrapper
public struct InfiniteFetch<Q: InfiniteQuery>: @MainActor DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var observer = InfiniteQueryObserver<Q>()
    private let query: Q

    public init(_ query: Q) {
        self.query = query
    }

    public var wrappedValue: InfiniteQueryHandle<Q> {
        InfiniteQueryHandle(observer: observer)
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
