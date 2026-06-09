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

    private struct Entry {
        var query: any Query
        var value: any Sendable
        var updatedAt: ContinuousClock.Instant
        var forcedStale: Bool
    }

    private let clock = ContinuousClock()
    private var entries: [CacheKey: Entry] = [:]
    private var inFlight: [CacheKey: Task<any Sendable, Error>] = [:]

    private var observerCounts: [CacheKey: Int] = [:]
    private var gcTasks: [CacheKey: Task<Void, Never>] = [:]

    private var eventStreams: [UUID: AsyncStream<CacheKey>.Continuation] = [:]

    // MARK: - Reading

    /// Cached value plus staleness, without fetching.
    func cachedValue<Q: Query>(for query: Q) -> CachedValue<Q.Value> {
        let key = CacheKey(query)
        guard let entry = entries[key] else {
            return CachedValue(value: nil, isStale: true)
        }
        let value = entry.value as? Q.Value
        let staleTime = query.staleTime ?? options.staleTime
        let isStale = entry.forcedStale || (clock.now - entry.updatedAt) >= staleTime
        return CachedValue(value: value, isStale: isStale)
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
            entries[key] = Entry(query: query, value: value, updatedAt: clock.now, forcedStale: false)
            notify(key)
            return value as! Q.Value
        } catch {
            inFlight[key] = nil
            notify(key)
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
        let gcTime = entry.query.gcTime ?? options.gcTime
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
    public func invalidate<Q: Query>(_ type: Q.Type) {
        for key in Array(entries.keys) {
            guard var entry = entries[key], entry.query is Q else { continue }
            entry.forcedStale = true
            entries[key] = entry
            notify(key)
        }
    }

    public func invalidate<Q: Query>(_ predicate: @Sendable (Q) -> Bool) {
        for key in Array(entries.keys) {
            guard var entry = entries[key], let query = entry.query as? Q, predicate(query) else { continue }
            entry.forcedStale = true
            entries[key] = entry
            notify(key)
        }
    }

    // MARK: - Removal

    /// Drop a type's cached queries. On-screen views lose their value and refetch cold.
    public func remove<Q: Query>(_ type: Q.Type) {
        for key in Array(entries.keys) where entries[key]?.query is Q {
            drop(key)
        }
    }

    public func remove<Q: Query>(_ predicate: @Sendable (Q) -> Bool) {
        for key in Array(entries.keys) {
            guard let query = entries[key]?.query as? Q, predicate(query) else { continue }
            drop(key)
        }
    }

    /// Clear everything, e.g. on logout.
    public func removeAll() {
        for key in Array(entries.keys) { drop(key) }
    }

    private func drop(_ key: CacheKey) {
        entries[key] = nil
        inFlight[key]?.cancel()
        inFlight[key] = nil
        notify(key)
    }
}

struct CachedValue<Value: Sendable>: Sendable {
    var value: Value?
    var isStale: Bool
}
