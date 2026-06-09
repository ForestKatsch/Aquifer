import Observation
import SwiftUI

/// Drives a single ``InfiniteQuery``'s ``InfiniteQueryState`` for a view. Mirrors ``QueryObserver``:
/// it retains the entry, reloads on the cache's change events, and catches errors here on the main
/// actor so `any Error` never crosses an isolation boundary. Adds the page-stepping actions.
@MainActor
@Observable
final class InfiniteQueryObserver<Q: InfiniteQuery> {
    private(set) var state = InfiniteQueryState<Q.Page>()

    @ObservationIgnored private var query: Q?
    @ObservationIgnored private var client: QueryClient?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var lastScenePhase: ScenePhase?

    init() {}

    /// No-op if already on the same query and client, so `update()` can call it every render.
    func start(_ query: Q, client: QueryClient) {
        if self.query == query, self.client === client { return }

        self.query = query
        self.client = client
        subscription?.cancel()

        let key = CacheKey(query)
        subscription = Task { [weak self] in
            await client.retain(key)
            let (id, stream) = await client.events()

            await self?.load(query, from: client)

            for await changed in stream {
                if changed == key {
                    await self?.load(query, from: client)
                }
            }

            await client.endEvents(id)
            await client.release(key)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        defer { lastScenePhase = phase }
        guard let last = lastScenePhase, last != .active, phase == .active else { return }
        refetchIfStale()
    }

    func refetchIfStale() {
        guard let query, let client else { return }
        guard client.options.refetchOnForeground else { return }
        Task { [weak self] in
            await self?.load(query, from: client)
        }
    }

    /// Load the first page, or refetch all loaded pages if they've gone stale. Sticky pages stay on
    /// screen meanwhile.
    private func load(_ query: Q, from client: QueryClient) async {
        let cached = await client.cachedPages(for: query)
        apply(cached.value, query: query)

        guard cached.value == nil || cached.isStale else { return }

        state.isFetching = true
        do {
            let value = try await client.fetchInfinite(query)
            apply(value, query: query)
            state.error = nil
        } catch is CancellationError {
            // Leave existing state untouched; a newer load or teardown superseded this one.
        } catch {
            state.error = error
        }
        state.isFetching = false
    }

    func fetchNextPage() async {
        guard let query, let client else { return }
        guard state.hasNextPage, !state.isFetchingNextPage else { return }

        state.isFetchingNextPage = true
        defer { state.isFetchingNextPage = false }
        do {
            let value = try await client.fetchNextPage(query)
            apply(value, query: query)
            state.error = nil
        } catch is CancellationError {
        } catch {
            state.error = error
        }
    }

    func fetchPreviousPage() async {
        guard let query, let client else { return }
        guard state.hasPreviousPage, !state.isFetchingPreviousPage else { return }

        state.isFetchingPreviousPage = true
        defer { state.isFetchingPreviousPage = false }
        do {
            let value = try await client.fetchPreviousPage(query)
            apply(value, query: query)
            state.error = nil
        } catch is CancellationError {
        } catch {
            state.error = error
        }
    }

    /// Push cached pages into `state` and recompute whether more pages exist on either side.
    private func apply(_ value: PagedValue<Q.Page, Q.PageParam>?, query: Q) {
        guard let value, !value.pages.isEmpty else {
            state.pages = []
            state.hasNextPage = false
            state.hasPreviousPage = false
            return
        }
        state.pages = value.pages
        state.hasNextPage = query.nextPageParam(
            after: value.pages[value.pages.count - 1], pages: value.pages, params: value.params
        ) != nil
        state.hasPreviousPage = query.previousPageParam(
            before: value.pages[0], pages: value.pages, params: value.params
        ) != nil
    }

    deinit {
        subscription?.cancel()
    }
}
