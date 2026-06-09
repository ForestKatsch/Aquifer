/// A ``QueryClient``'s defaults. A query overrides them with its own ``Query/staleTime`` / ``Query/gcTime``.
public struct QueryOptions: Sendable {
    public var staleTime: Duration
    public var gcTime: Duration

    /// Refetch stale on-screen queries when the app returns to the foreground.
    public var refetchOnForeground: Bool

    public init(
        staleTime: Duration = .seconds(5),
        gcTime: Duration = .seconds(300),
        refetchOnForeground: Bool = true
    ) {
        self.staleTime = staleTime
        self.gcTime = gcTime
        self.refetchOnForeground = refetchOnForeground
    }
}
