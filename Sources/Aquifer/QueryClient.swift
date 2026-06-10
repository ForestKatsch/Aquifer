import Foundation

/// The cache. Dedupes in-flight requests, runs stale-while-revalidate, garbage-collects unused
/// entries. Inject one with `.queryClient(_:)`.
///
/// All shared mutable state lives behind this actor. Only `Sendable` things cross out — values as
/// results, errors via `throws`, change notifications as bare keys — so the library stays race-free.
public actor QueryClient {
    public let options: QueryOptions

    public init(options: QueryOptions = QueryOptions()) {
        self.options = options
    }

    // MARK: - Storage

    /// Holds either a ``Query`` or an ``InfiniteQuery``. `query` is the concrete struct (kept for
    /// type/predicate matching in invalidate/remove); `staleTime`/`gcTime` are resolved from it at
    /// store time so the lifecycle code never has to cast back through an existential.
    ///
    /// An entry records *both* outcomes. `value`/`updatedAt` are the last **success** and stay sticky
    /// across a later failure (stale-while-revalidate). `failedAt`/`failureCount`/`error` track the
    /// last **failure**; `failedAt == nil` means the most recent attempt succeeded. An entry can
    /// therefore exist with no value at all — a key that has only ever failed — which is what lets
    /// "never fetched" and "fetched and failed" be different states.
    private struct Entry {
        var query: any Sendable
        var value: (any Sendable)?
        var updatedAt: ContinuousClock.Instant?
        var forcedStale: Bool
        var failedAt: ContinuousClock.Instant?
        var failureCount: Int
        var error: (any Error)?
        var staleTime: Duration?
        var gcTime: Duration?
    }

    private let clock = ContinuousClock()
    private var entries: [CacheKey: Entry] = [:]
    private var inFlight: [CacheKey: Task<any Sendable, Error>] = [:]

    /// Per-page requests for infinite queries, keyed by entry *and* direction, so a "next page" and a
    /// "previous page" for the same query can be in flight at once while duplicates of each still join.
    private enum PageDirection: Hashable { case refetch, next, previous }
    private struct PageFlightKey: Hashable {
        var key: CacheKey
        var direction: PageDirection
    }
    private var pageFlights: [PageFlightKey: Task<any Sendable, Error>] = [:]

    private var observerCounts: [CacheKey: Int] = [:]
    private var gcTasks: [CacheKey: Task<Void, Never>] = [:]

    private var eventStreams: [UUID: AsyncStream<CacheKey>.Continuation] = [:]

    // MARK: - Reading

    /// Cached value plus staleness and failure summary, without fetching. The `Error` itself is not
    /// returned (it isn't `Sendable`); read it with ``surfaceError(for:)``.
    func cachedValue<Q: Query>(for query: Q) -> CachedValue<Q.Value> {
        let key = CacheKey(query)
        guard let entry = entries[key] else {
            return CachedValue(value: nil, isStale: true)
        }
        return CachedValue(
            value: entry.value as? Q.Value,
            isStale: isStale(entry),
            failureCount: entry.failureCount,
            isError: entry.failedAt != nil
        )
    }

    private func isStale(_ entry: Entry) -> Bool {
        guard let updatedAt = entry.updatedAt else { return true }   // never succeeded
        let staleTime = entry.staleTime ?? options.staleTime
        return entry.forcedStale || (clock.now - updatedAt) >= staleTime
    }

    // MARK: - Fetch eligibility & failure state

    /// Whether a fetch should run *now*. The fix for the failed-fetch storm: a key that has only ever
    /// failed is no longer treated as "cold" — during backoff and after the retry cap this returns
    /// `false`, so a change notification re-reads state without kicking off another doomed request.
    func shouldFetch<Q: Query>(for query: Q) -> Bool {
        shouldFetch(key: CacheKey(query), retry: query.retry, retryDelay: query.retryDelay)
    }

    func shouldFetch<Q: InfiniteQuery>(for query: Q) -> Bool {
        shouldFetch(key: CacheKey(query), retry: query.retry, retryDelay: query.retryDelay)
    }

    private func shouldFetch(key: CacheKey, retry: Int?, retryDelay: Duration?) -> Bool {
        guard let entry = entries[key] else { return true }   // cold: never attempted
        if let failedAt = entry.failedAt {                    // last attempt failed
            guard entry.failureCount < (retry ?? options.retry) else { return false }   // exhausted
            let delay = RetryPolicy.backoff(
                failureCount: entry.failureCount,
                base: retryDelay ?? options.retryDelay,
                cap: options.maxRetryDelay
            )
            return (clock.now - failedAt) >= delay   // only after backoff
        }
        return entry.value == nil || isStale(entry)   // last attempt succeeded → normal SWR
    }

    /// Throw the entry's recorded error, if its last attempt failed. Lets an observer that *didn't*
    /// run the failing fetch still surface the error, without crossing a non-`Sendable` value out as
    /// a return — `throws` is the one channel an `any Error` may use.
    func surfaceError<Q: Query>(for query: Q) throws { try surfaceError(key: CacheKey(query)) }
    func surfaceError<Q: InfiniteQuery>(for query: Q) throws { try surfaceError(key: CacheKey(query)) }
    private func surfaceError(key: CacheKey) throws {
        if let error = entries[key]?.error { throw error }
    }

    /// Reset an entry's failure state and mark it stale, so the next ``shouldFetch`` says yes. The
    /// recovery path out of a terminal error: invalidate, refetch, and foreground all route here.
    func markForRetry<Q: Query>(for query: Q) { markForRetry(key: CacheKey(query)) }
    func markForRetry<Q: InfiniteQuery>(for query: Q) { markForRetry(key: CacheKey(query)) }
    private func markForRetry(key: CacheKey) {
        guard var entry = entries[key] else { return }
        entry.failedAt = nil
        entry.failureCount = 0
        entry.error = nil
        entry.forcedStale = true
        entries[key] = entry
        notify(key)
    }

    /// Record a failed attempt on the entry, preserving any last-good value (stale-while-revalidate).
    /// Creates a value-less entry if the key has never succeeded. Cancellation is *not* a failure.
    private func recordFailure(_ key: CacheKey, query: any Sendable, error: any Error, staleTime: Duration?, gcTime: Duration?) {
        if error is CancellationError { return }
        var entry = entries[key] ?? Entry(
            query: query, value: nil, updatedAt: nil, forcedStale: false,
            failedAt: nil, failureCount: 0, error: nil, staleTime: staleTime, gcTime: gcTime
        )
        entry.failedAt = clock.now
        entry.failureCount += 1
        entry.error = error
        entries[key] = entry
    }

    // MARK: - Fetching

    /// Fetch and store, sharing one request across concurrent callers for the same key.
    func fetch<Q: Query>(_ query: Q) async throws -> Q.Value {
        let key = CacheKey(query)

        if let existing = inFlight[key] {
            let value = try await existing.value
            return value as! Q.Value
        }

        let task = Task<any Sendable, Error> {
            try await query.fetch()
        }
        inFlight[key] = task

        do {
            let value = try await task.value
            inFlight[key] = nil
            entries[key] = Entry(
                query: query, value: value, updatedAt: clock.now, forcedStale: false,
                failedAt: nil, failureCount: 0, error: nil,
                staleTime: query.staleTime, gcTime: query.gcTime
            )
            notify(key)
            return value as! Q.Value
        } catch {
            inFlight[key] = nil
            recordFailure(key, query: query, error: error, staleTime: query.staleTime, gcTime: query.gcTime)
            notify(key)
            throw error
        }
    }

    // MARK: - Infinite fetching

    /// Cached pages plus staleness, without fetching.
    func cachedPages<Q: InfiniteQuery>(for query: Q) -> CachedValue<PagedValue<Q.Page, Q.PageParam>> {
        let key = CacheKey(query)
        guard let entry = entries[key] else {
            return CachedValue(value: nil, isStale: true)
        }
        return CachedValue(
            value: entry.value as? PagedValue<Q.Page, Q.PageParam>,
            isStale: isStale(entry),
            failureCount: entry.failureCount,
            isError: entry.failedAt != nil
        )
    }

    /// Load the first page, or — if pages already exist — refetch every loaded page in order,
    /// threading cursors from `initialPageParam` so the list stays consistent even if the backend's
    /// pagination drifted. One request per key; concurrent callers join it.
    @discardableResult
    func fetchInfinite<Q: InfiniteQuery>(_ query: Q) async throws -> PagedValue<Q.Page, Q.PageParam> {
        let key = CacheKey(query)
        let flightKey = PageFlightKey(key: key, direction: .refetch)
        if let existing = pageFlights[flightKey] {
            return try await existing.value as! PagedValue<Q.Page, Q.PageParam>
        }

        let existingCount = (entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>)?.pages.count ?? 0
        let pageCount = max(existingCount, 1)
        let task = Task<any Sendable, Error> {
            var pages: [Q.Page] = []
            var params: [Q.PageParam] = []
            var param: Q.PageParam? = query.initialPageParam
            for _ in 0..<pageCount {
                guard let p = param else { break }
                let page = try await query.fetch(page: p)
                pages.append(page)
                params.append(p)
                param = query.nextPageParam(after: page, pages: pages, params: params)
            }
            return PagedValue(pages: pages, params: params)
        }
        return try await store(task, key: key, flightKey: flightKey, query: query, recordsFailure: true)
    }

    /// Append the page after the last one. No-op if there are no pages yet or no next cursor.
    @discardableResult
    func fetchNextPage<Q: InfiniteQuery>(_ query: Q) async throws -> PagedValue<Q.Page, Q.PageParam> {
        let key = CacheKey(query)
        let flightKey = PageFlightKey(key: key, direction: .next)
        if let existing = pageFlights[flightKey] {
            return try await existing.value as! PagedValue<Q.Page, Q.PageParam>
        }
        guard let base = entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>,
              let last = base.pages.last,
              let param = query.nextPageParam(after: last, pages: base.pages, params: base.params)
        else {
            return (entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>) ?? PagedValue()
        }

        let task = Task<any Sendable, Error> {
            let page = try await query.fetch(page: param)
            return PagedValue(pages: base.pages + [page], params: base.params + [param])
        }
        return try await store(task, key: key, flightKey: flightKey, query: query, recordsFailure: false)
    }

    /// Prepend the page before the first one. No-op if there are no pages yet or no previous cursor.
    @discardableResult
    func fetchPreviousPage<Q: InfiniteQuery>(_ query: Q) async throws -> PagedValue<Q.Page, Q.PageParam> {
        let key = CacheKey(query)
        let flightKey = PageFlightKey(key: key, direction: .previous)
        if let existing = pageFlights[flightKey] {
            return try await existing.value as! PagedValue<Q.Page, Q.PageParam>
        }
        guard let base = entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>,
              let first = base.pages.first,
              let param = query.previousPageParam(before: first, pages: base.pages, params: base.params)
        else {
            return (entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>) ?? PagedValue()
        }

        let task = Task<any Sendable, Error> {
            let page = try await query.fetch(page: param)
            return PagedValue(pages: [page] + base.pages, params: [param] + base.params)
        }
        return try await store(task, key: key, flightKey: flightKey, query: query, recordsFailure: false)
    }

    /// Await a page task, store its result as the entry's value, and clear the in-flight slot.
    ///
    /// `recordsFailure` is true only for the initial/refetch direction: that's the notify-driven
    /// `load` path that could storm. A `fetchNextPage`/`fetchPreviousPage` failure is user-triggered
    /// (a scroll), so it surfaces its error but must not set the entry's `failedAt` — otherwise it
    /// would wrongly gate the whole-list load behind backoff.
    private func store<Q: InfiniteQuery>(
        _ task: Task<any Sendable, Error>, key: CacheKey, flightKey: PageFlightKey, query: Q,
        recordsFailure: Bool
    ) async throws -> PagedValue<Q.Page, Q.PageParam> {
        pageFlights[flightKey] = task
        do {
            let value = try await task.value
            pageFlights[flightKey] = nil
            entries[key] = Entry(
                query: query, value: value, updatedAt: clock.now, forcedStale: false,
                failedAt: nil, failureCount: 0, error: nil,
                staleTime: query.staleTime, gcTime: query.gcTime
            )
            notify(key)
            return value as! PagedValue<Q.Page, Q.PageParam>
        } catch {
            pageFlights[flightKey] = nil
            if recordsFailure {
                // Recorded a load failure: cache state changed, so wake observers to surface it.
                recordFailure(key, query: query, error: error, staleTime: query.staleTime, gcTime: query.gcTime)
                notify(key)
            }
            // A next/previous-page failure changed nothing cached; the caller surfaces its own error.
            throw error
        }
    }

    // MARK: - Observation lifecycle

    /// While at least one observer is retained, the entry is never garbage-collected.
    func retain(_ key: CacheKey) {
        observerCounts[key, default: 0] += 1
        gcTasks[key]?.cancel()
        gcTasks[key] = nil
    }

    /// On the last observer leaving, schedule eviction after `gcTime`.
    func release(_ key: CacheKey) {
        guard let count = observerCounts[key], count > 0 else { return }
        if count == 1 {
            observerCounts[key] = nil
            scheduleGC(key)
        } else {
            observerCounts[key] = count - 1
        }
    }

    private func scheduleGC(_ key: CacheKey) {
        guard let entry = entries[key] else { return }
        let gcTime = entry.gcTime ?? options.gcTime
        gcTasks[key]?.cancel()
        gcTasks[key] = Task { [self] in
            try? await Task.sleep(for: gcTime)
            evictIfUnused(key)
        }
    }

    private func evictIfUnused(_ key: CacheKey) {
        guard observerCounts[key] == nil else { return }
        entries[key] = nil
        gcTasks[key] = nil
    }

    // MARK: - Change notifications

    /// Observers consume this and re-read the keys they care about. Only the key crosses out.
    func events() -> (id: UUID, stream: AsyncStream<CacheKey>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CacheKey>.makeStream()
        eventStreams[id] = continuation
        return (id, stream)
    }

    func endEvents(_ id: UUID) {
        eventStreams[id]?.finish()
        eventStreams[id] = nil
    }

    private func notify(_ key: CacheKey) {
        for continuation in eventStreams.values {
            continuation.yield(key)
        }
    }

    // MARK: - Invalidation

    /// Mark a type's cached queries stale. On-screen ones refetch now; the rest on next appearance.
    /// Works the same for ``InfiniteQuery`` entries — their loaded pages are kept and refetched.
    public func invalidate<Q: Query>(_ type: Q.Type) { invalidate(where: { $0 is Q }) }
    public func invalidate<Q: Query>(_ predicate: @Sendable (Q) -> Bool) {
        invalidate(where: { ($0 as? Q).map(predicate) ?? false })
    }
    public func invalidate<Q: InfiniteQuery>(_ type: Q.Type) { invalidate(where: { $0 is Q }) }
    public func invalidate<Q: InfiniteQuery>(_ predicate: @Sendable (Q) -> Bool) {
        invalidate(where: { ($0 as? Q).map(predicate) ?? false })
    }

    private func invalidate(where matches: (any Sendable) -> Bool) {
        for key in Array(entries.keys) {
            guard var entry = entries[key], matches(entry.query) else { continue }
            entry.forcedStale = true
            // Invalidation is also a recovery trigger: clear any failure so a terminal query refetches.
            entry.failedAt = nil
            entry.failureCount = 0
            entry.error = nil
            entries[key] = entry
            notify(key)
        }
    }

    // MARK: - Removal

    /// Drop a type's cached queries. On-screen views lose their value and refetch cold.
    public func remove<Q: Query>(_ type: Q.Type) { drop(where: { $0 is Q }) }
    public func remove<Q: Query>(_ predicate: @Sendable (Q) -> Bool) {
        drop(where: { ($0 as? Q).map(predicate) ?? false })
    }
    public func remove<Q: InfiniteQuery>(_ type: Q.Type) { drop(where: { $0 is Q }) }
    public func remove<Q: InfiniteQuery>(_ predicate: @Sendable (Q) -> Bool) {
        drop(where: { ($0 as? Q).map(predicate) ?? false })
    }

    /// Clear everything, e.g. on logout.
    public func removeAll() {
        for key in Array(entries.keys) { drop(key) }
    }

    private func drop(where matches: (any Sendable) -> Bool) {
        for key in Array(entries.keys) {
            guard let entry = entries[key], matches(entry.query) else { continue }
            drop(key)
        }
    }

    private func drop(_ key: CacheKey) {
        entries[key] = nil
        inFlight[key]?.cancel()
        inFlight[key] = nil
        for flightKey in pageFlights.keys where flightKey.key == key {
            pageFlights[flightKey]?.cancel()
            pageFlights[flightKey] = nil
        }
        notify(key)
    }
}

struct CachedValue<Value: Sendable>: Sendable {
    var value: Value?
    var isStale: Bool
    var failureCount: Int = 0
    var isError: Bool = false
}
