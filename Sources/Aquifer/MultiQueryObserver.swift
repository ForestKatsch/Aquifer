import Observation
import SwiftUI

/// Combines several queries into one ``QueryState``. Owns one ``QueryObserver`` per query, so each
/// stays independently cached and invalidated. Value when all succeed, error/fetching if any.
@MainActor
@Observable
final class MultiQueryObserver<each Q: Query> {
    @ObservationIgnored private let observers: (repeat QueryObserver<each Q>)
    @ObservationIgnored private var lastScenePhase: ScenePhase?

    init() {
        observers = (repeat QueryObserver<each Q>())
    }

    func start(_ queries: repeat each Q, client: QueryClient) {
        repeat (each observers).start(each queries, client: client)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        defer { lastScenePhase = phase }
        guard let last = lastScenePhase, last != .active, phase == .active else { return }
        for observer in repeat (each observers) {
            observer.refetchIfStale()
        }
    }

    var state: QueryState<(repeat (each Q).Value)> {
        var isFetching = false
        var firstError: Error?
        for observer in repeat (each observers) {
            isFetching = isFetching || observer.state.isFetching
            if firstError == nil { firstError = observer.state.error }
        }
        return QueryState<(repeat (each Q).Value)>(
            value: combinedValue(),
            error: firstError,
            isFetching: isFetching
        )
    }

    private func combinedValue() -> (repeat (each Q).Value)? {
        do {
            return (repeat try Self.require((each observers).state.value))
        } catch {
            return nil
        }
    }

    private struct Missing: Error {}

    private static func require<V>(_ value: V?) throws -> V {
        guard let value else { throw Missing() }
        return value
    }
}
