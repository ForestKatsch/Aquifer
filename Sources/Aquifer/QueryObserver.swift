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
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init() {}

    /// No-op if already on the same query and client, so `update()` can call it every render.
    func start(_ query: Q, client: QueryClient) {
        if self.query == query, self.client === client { return }

        self.query = query
        self.client = client
        subscription?.cancel()
        retryTask?.cancel()   // a pending backoff retry belongs to the old query; drop it
        retryTask = nil

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
            guard let self else { return }
            // Foreground is a recovery trigger: a terminal-errored query resets and tries again.
            if self.state.isError {
                await client.markForRetry(for: query)   // notify → load refetches
            } else {
                await self.load(query, from: client)
            }
        }
    }

    /// Manually force a fresh fetch — pull-to-refresh, a Retry button. Clears any terminal error.
    func refetch() {
        guard let query, let client else { return }
        Task { [weak self] in
            await client.markForRetry(for: query)
            await self?.load(query, from: client)
        }
    }

    private func load(_ query: Q, from client: QueryClient) async {
        let cached = await client.cachedValue(for: query)
        state.value = cached.value
        state.failureCount = cached.failureCount

        guard await client.shouldFetch(for: query) else {
            // Not fetching — but a sibling may have recorded an error we should surface.
            await surfaceCachedError(query, from: client)
            scheduleRetryIfEligible(query, client)
            return
        }

        state.isFetching = true
        do {
            state.value = try await client.fetch(query)
            state.error = nil
            state.isError = false
        } catch is CancellationError {
            // Leave existing state untouched; a newer load or teardown superseded this one.
            state.isFetching = false
            return
        } catch {
            state.error = error
            state.isError = true
        }
        state.isFetching = false
        state.failureCount = await client.cachedValue(for: query).failureCount
        scheduleRetryIfEligible(query, client)
    }

    /// Pull the entry's recorded error (if any) into `state` without fetching.
    private func surfaceCachedError(_ query: Q, from client: QueryClient) async {
        do {
            try await client.surfaceError(for: query)
            state.error = nil
            state.isError = false
        } catch is CancellationError {
        } catch {
            state.error = error
            state.isError = true
        }
    }

    /// After a failed attempt, schedule one delayed reload with exponential backoff — unless the
    /// retry budget is spent, in which case the query rests in its terminal error. Each observer keeps
    /// its own timer; requests are deduped by key, so concurrent observers collapse to one fetch.
    private func scheduleRetryIfEligible(_ query: Q, _ client: QueryClient) {
        retryTask?.cancel()
        retryTask = nil
        guard state.isError, state.failureCount < (query.retry ?? client.options.retry) else { return }

        let delay = RetryPolicy.backoff(
            failureCount: state.failureCount,
            base: query.retryDelay ?? client.options.retryDelay,
            cap: client.options.maxRetryDelay
        )
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.load(query, from: client)
        }
    }

    deinit {
        subscription?.cancel()
        retryTask?.cancel()
    }
}
