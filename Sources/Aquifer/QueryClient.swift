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
            isError: entry.failedAt != nil,
            forcedStale: entry.forcedStale
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

    /// Reset an entry's failure state and mark it stale, so the next ``shouldFetch`` says yes, then
    /// `notify` so observers reload. For recovery triggers that don't await a load themselves —
    /// returning to the foreground out of a terminal error.
    func markForRetry<Q: Query>(for query: Q) { markForRetry(key: CacheKey(query)) }
    func markForRetry<Q: InfiniteQuery>(for query: Q) { markForRetry(key: CacheKey(query)) }
    private func markForRetry(key: CacheKey) {
        forceStaleKeepingValue(key: key)
        notify(key)
    }

    /// Mark the entry stale and clear its failure gate, **keeping** the cached value
    /// (stale-while-revalidate). Unlike ``markForRetry``, this does **not** `notify`: it's for an
    /// explicit `refetch()` that immediately awaits its own `load()`. Notifying here would wake
    /// observers — including the caller — into a second, concurrent load; mid-`.refreshable` that
    /// extra load mutates state and tears the spinner down before the awaited load finishes.
    func forceStaleKeepingValue<Q: Query>(for query: Q) { forceStaleKeepingValue(key: CacheKey(query)) }
    func forceStaleKeepingValue<Q: InfiniteQuery>(for query: Q) { forceStaleKeepingValue(key: CacheKey(query)) }
    private func forceStaleKeepingValue(key: CacheKey) {
        guard var entry = entries[key] else { return }
        entry.failedAt = nil
        entry.failureCount = 0
        entry.error = nil
        entry.forcedStale = true
        entries[key] = entry
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
        scheduleGCIfUnobserved(key)
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
            // Only clear the slot if it is still *this* task: a `drop` during the flight may have
            // cleared it and a newer fetch may already own it.
            if inFlight[key] == task { inFlight[key] = nil }
            entries[key] = Entry(
                query: query, value: value, updatedAt: clock.now, forcedStale: false,
                failedAt: nil, failureCount: 0, error: nil,
                staleTime: query.staleTime, gcTime: query.gcTime
            )
            scheduleGCIfUnobserved(key)
            notify(key)
            return value as! Q.Value
        } catch {
            if inFlight[key] == task { inFlight[key] = nil }
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
            isError: entry.failedAt != nil,
            forcedStale: entry.forcedStale
        )
    }

    /// Reload the query's pages according to its ``InfiniteQuery/revalidation`` policy.
    ///
    /// The default policy reloads only the first page and leaves the pages after it in place: one
    /// request, and a reader scrolled ten pages deep keeps their position. ``InfiniteRevalidation/allPages``
    /// restores the re-thread-everything behaviour. One request per key and direction; concurrent
    /// callers join it.
    ///
    /// `explicit` marks a user-driven reload (pull-to-refresh, a Retry button). It upgrades the
    /// ``InfiniteRevalidation/none`` policy to ``InfiniteRevalidation/firstPage``, so "don't reload
    /// in the background" never means "the refresh control does nothing".
    @discardableResult
    func fetchInfinite<Q: InfiniteQuery>(_ query: Q, explicit: Bool = false) async throws -> PagedValue<Q.Page, Q.PageParam> {
        let key = CacheKey(query)
        let flightKey = PageFlightKey(key: key, direction: .refetch)
        if let existing = pageFlights[flightKey] {
            return try await existing.value as! PagedValue<Q.Page, Q.PageParam>
        }

        let existing = entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>
        let loaded = existing?.pages.count ?? 0

        var policy = query.revalidation
        if policy == .none, explicit { policy = .firstPage }
        // Nothing loaded yet: there is no position to preserve and no cheaper option than page one.
        if loaded == 0 { policy = .firstPage }

        if policy == .none {
            return existing ?? PagedValue()
        }

        if policy == .firstPage {
            return try await fetchFirstPage(key: key, flightKey: flightKey, query: query)
        }

        // .allPages: re-thread every cursor from the start. This deliberately replaces the whole
        // list, so a page appended while it was running is superseded rather than merged.
        let task = Task<any Sendable, Error> {
            var pages: [Q.Page] = []
            var params: [Q.PageParam] = []
            var param: Q.PageParam? = query.initialPageParam
            for _ in 0 ..< max(loaded, 1) {
                guard let p = param else { break }
                let page = try await query.fetch(page: p)
                pages.append(page)
                params.append(p)
                param = query.nextPageParam(after: page, pages: pages, params: params)
            }
            return query.reconcile(PagedValue(pages: pages, params: params))
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

        return try await fetchPage(
            key: key, flightKey: flightKey, query: query,
            baseParams: base.params, param: param, prepend: false
        )
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

        return try await fetchPage(
            key: key, flightKey: flightKey, query: query,
            baseParams: base.params, param: param, prepend: true
        )
    }

    /// Reload page one and splice it into the list in place, leaving the pages after it alone.
    ///
    /// Like ``fetchPage``, the splice happens inside the flight task and reads the entry as it is
    /// *then*: a page the reader appended by scrolling while this was in flight must not be undone
    /// by writing back the snapshot this reload started from.
    private func fetchFirstPage<Q: InfiniteQuery>(
        key: CacheKey, flightKey: PageFlightKey, query: Q
    ) async throws -> PagedValue<Q.Page, Q.PageParam> {
        let param = query.initialPageParam
        let task = Task<any Sendable, Error> { [self] in
            let page = try await query.fetch(page: param)
            return commitFirstPage(page: page, key: key, query: query, param: param)
        }
        pageFlights[flightKey] = task
        do {
            let value = try await task.value as! PagedValue<Q.Page, Q.PageParam>
            if pageFlights[flightKey] == task { pageFlights[flightKey] = nil }
            return value
        } catch {
            if pageFlights[flightKey] == task { pageFlights[flightKey] = nil }
            // This is the notify-driven load path, so a failure is recorded and surfaced.
            recordFailure(key, query: query, error: error, staleTime: query.staleTime, gcTime: query.gcTime)
            notify(key)
            throw error
        }
    }

    private func commitFirstPage<Q: InfiniteQuery>(
        page: Q.Page, key: CacheKey, query: Q, param: Q.PageParam
    ) -> PagedValue<Q.Page, Q.PageParam> {
        let current = entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>
        var merged = PagedValue(pages: [page], params: [param])
        if var pages = current?.pages, var params = current?.params,
           pages.count > 1, params.count == pages.count {
            pages[0] = page
            params[0] = param
            merged = PagedValue(pages: pages, params: params)
        }
        merged = query.reconcile(merged)
        storeValue(merged, key: key, query: query)
        notify(key)
        return merged
    }

    /// Load one page and splice it into the list.
    ///
    /// The commit happens *inside* the flight task, so a second caller that joins this task gets
    /// the same merged list rather than a bare page — and sees it only once it is cached.
    private func fetchPage<Q: InfiniteQuery>(
        key: CacheKey, flightKey: PageFlightKey, query: Q,
        baseParams: [Q.PageParam], param: Q.PageParam, prepend: Bool
    ) async throws -> PagedValue<Q.Page, Q.PageParam> {
        let task = Task<any Sendable, Error> { [self] in
            let page = try await query.fetch(page: param)
            return commit(
                page: page, key: key, query: query,
                baseParams: baseParams, param: param, prepend: prepend
            )
        }
        pageFlights[flightKey] = task
        do {
            let value = try await task.value as! PagedValue<Q.Page, Q.PageParam>
            if pageFlights[flightKey] == task { pageFlights[flightKey] = nil }
            return value
        } catch {
            if pageFlights[flightKey] == task { pageFlights[flightKey] = nil }
            // A next/previous-page failure changed nothing cached; the caller surfaces its own error.
            throw error
        }
    }

    /// Splice a freshly loaded page onto whatever is cached **at commit time**.
    ///
    /// The page was requested against a snapshot of the list; by the time it lands a revalidation
    /// may have replaced that list. Writing `snapshot + page` would then throw the fresh pages away.
    /// So we re-read the entry and only append when the cursor list still matches the one we
    /// paginated from — otherwise the page belongs to a list that no longer exists and is dropped.
    private func commit<Q: InfiniteQuery>(
        page: Q.Page, key: CacheKey, query: Q,
        baseParams: [Q.PageParam], param: Q.PageParam, prepend: Bool
    ) -> PagedValue<Q.Page, Q.PageParam> {
        let current = (entries[key]?.value as? PagedValue<Q.Page, Q.PageParam>) ?? PagedValue()
        guard current.params == baseParams else { return current }

        let merged = query.reconcile(
            prepend
                ? PagedValue(pages: [page] + current.pages, params: [param] + current.params)
                : PagedValue(pages: current.pages + [page], params: current.params + [param])
        )
        storeValue(merged, key: key, query: query)
        notify(key)
        return merged
    }

    /// Await a whole-list task, store its result as the entry's value, and clear the in-flight slot.
    ///
    /// `recordsFailure` is true only for the initial/refetch direction: that's the notify-driven
    /// `load` path that could storm.
    private func store<Q: InfiniteQuery>(
        _ task: Task<any Sendable, Error>, key: CacheKey, flightKey: PageFlightKey, query: Q,
        recordsFailure: Bool
    ) async throws -> PagedValue<Q.Page, Q.PageParam> {
        pageFlights[flightKey] = task
        do {
            let value = try await task.value as! PagedValue<Q.Page, Q.PageParam>
            if pageFlights[flightKey] == task { pageFlights[flightKey] = nil }
            storeValue(value, key: key, query: query)
            notify(key)
            return value
        } catch {
            if pageFlights[flightKey] == task { pageFlights[flightKey] = nil }
            if recordsFailure {
                // Recorded a load failure: cache state changed, so wake observers to surface it.
                recordFailure(key, query: query, error: error, staleTime: query.staleTime, gcTime: query.gcTime)
                notify(key)
            }
            throw error
        }
    }

    private func storeValue<Q: InfiniteQuery>(
        _ value: PagedValue<Q.Page, Q.PageParam>, key: CacheKey, query: Q
    ) {
        entries[key] = Entry(
            query: query, value: value, updatedAt: clock.now, forcedStale: false,
            failedAt: nil, failureCount: 0, error: nil,
            staleTime: query.staleTime, gcTime: query.gcTime
        )
        scheduleGCIfUnobserved(key)
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

    /// An entry whose fetch lands *after* its last observer left was never scheduled for eviction —
    /// `release` ran while the entry did not exist yet, and `scheduleGC` bailed out. Called from
    /// every store so such an entry still gets collected.
    private func scheduleGCIfUnobserved(_ key: CacheKey) {
        guard observerCounts[key] == nil, gcTasks[key] == nil else { return }
        scheduleGC(key)
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
    /// Someone explicitly invalidated this entry (rather than it merely ageing out). A change
    /// notification only sends an observer fetching when this — or a missing value, or a retryable
    /// failure — is true.
    var forcedStale: Bool = false
}
