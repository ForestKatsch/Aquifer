/// A ``QueryClient``'s defaults. A query overrides them with its own ``Query/staleTime`` / ``Query/gcTime``.
public struct QueryOptions: Sendable {
    public var staleTime: Duration
    public var gcTime: Duration

    /// Refetch stale on-screen queries when the app returns to the foreground.
    public var refetchOnForeground: Bool

    /// How many attempts a failing query gets before it rests in a terminal error state. `1` means
    /// no retry. After the cap, only an explicit trigger (invalidate, remove, refetch, foreground)
    /// resumes it.
    public var retry: Int

    /// Base delay before the first retry. Subsequent retries back off exponentially
    /// (`retryDelay · 2ⁿ`), capped at ``maxRetryDelay``.
    public var retryDelay: Duration

    /// Upper bound on the exponential backoff between retries.
    public var maxRetryDelay: Duration

    public init(
        staleTime: Duration = .seconds(5),
        gcTime: Duration = .seconds(300),
        refetchOnForeground: Bool = true,
        retry: Int = 3,
        retryDelay: Duration = .seconds(1),
        maxRetryDelay: Duration = .seconds(30)
    ) {
        self.staleTime = staleTime
        self.gcTime = gcTime
        self.refetchOnForeground = refetchOnForeground
        self.retry = retry
        self.retryDelay = retryDelay
        self.maxRetryDelay = maxRetryDelay
    }
}
