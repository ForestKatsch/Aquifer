/// Something to fetch. Its `Hashable` identity is its cache key — equal queries share one entry and
/// one in-flight request. Stored properties are the parameters; `fetch()` is the request.
public protocol Query: Hashable, Sendable {
  /// `Sendable` so it can cross the cache's actor boundary.
  associatedtype Value: Sendable

  func fetch() async throws -> Value

  /// How long a cached value stays fresh. `nil` uses the ``QueryClient``'s value.
  var staleTime: Duration? { get }

  /// How long an unused value is kept after its last observer leaves. `nil` uses the client's.
  var gcTime: Duration? { get }
}

extension Query {
  public var staleTime: Duration? { nil }
  public var gcTime: Duration? { nil }
}
