import Observation
import SwiftUI

/// Drives a single query's ``QueryState`` for a view. Errors are caught here, on the main actor, so
/// `any Error` never crosses an isolation boundary.
@MainActor
@Observable
final class QueryObserver<Q: Query> {
    private(set) var state = QueryState<Q.Value>()

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

            // The stream ends when this task is cancelled (deinit / restart), so cleanup runs here.
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

    private func load(_ query: Q, from client: QueryClient) async {
        let cached = await client.cachedValue(for: query)
        state.value = cached.value

        guard cached.value == nil || cached.isStale else { return }

        state.isFetching = true
        do {
            state.value = try await client.fetch(query)
            state.error = nil
        } catch is CancellationError {
            // Leave existing state untouched; a newer load or teardown superseded this one.
        } catch {
            state.error = error
        }
        state.isFetching = false
    }

    deinit {
        subscription?.cancel()
    }
}
