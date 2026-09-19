import Observation
import SwiftUI

/// Why an observer is reloading. A `.notification` reload re-reads the cache; it only fetches when
/// the entry genuinely needs it (see `load`).
enum LoadTrigger {
    /// Mounting, or returning to the foreground.
    case direct
    /// The cache raised a change event for this key.
    case notification
    /// The user asked: pull-to-refresh, or a Retry button.
    case explicit
}

/// Drives a single query's ``QueryState`` for a view. Errors are caught here, on the main actor, so
/// `any Error` never crosses an isolation boundary.
@MainActor
@Observable
final class QueryObserver<Q: Query> {
    private(set) var state = QueryState<Q.Value>()

    @ObservationIgnored private var query: Q?
    @ObservationIgnored private var client: QueryClient?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    /// Set the moment the scene actually backgrounds. `.inactive` alone — Control Centre, the app
    /// switcher, a permission alert, Slide Over — is *not* a background, and must not trigger a
    /// reload: that was a full refetch every time a notification banner slid down.
    @ObservationIgnored private var wasBackgrounded = false
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
                    await self?.load(query, from: client, trigger: .notification)
                }
            }

            // The stream ends when this task is cancelled (deinit / restart), so cleanup runs here.
            await client.endEvents(id)
            await client.release(key)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background {
            wasBackgrounded = true
        } else if phase == .active, wasBackgrounded {
            wasBackgrounded = false
            refetchIfStale()
        }
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
        Task { [weak self] in await self?.refetch() }
    }

    /// Awaitable form: completes when the load settles, so a `.refreshable` spinner can track it.
    /// Invalidate (keeping the value) without notifying, then run a single awaited load — so the
    /// spinner tracks exactly this fetch instead of a notify-spawned concurrent one.
    func refetch() async {
        guard let query, let client else { return }
        await client.forceStaleKeepingValue(for: query)
        await load(query, from: client, trigger: .explicit)
    }

    private func load(_ query: Q, from client: QueryClient, trigger: LoadTrigger = .direct) async {
        let cached = await client.cachedValue(for: query)
        state.value = cached.value
        state.failureCount = cached.failureCount

        // A change notification means the cache moved, and the right response is to re-read it.
        // Starting a fetch from here as well is what let `staleTime: .zero` spin forever: every
        // success notifies us, and we are instantly stale again. Only a value that has gone away,
        // an explicit invalidation, or a retryable failure warrants fetching off a notification;
        // plain ageing is picked up by mount, foreground and explicit refresh.
        if trigger == .notification, !(cached.value == nil || cached.forcedStale || cached.isError) {
            return
        }

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
