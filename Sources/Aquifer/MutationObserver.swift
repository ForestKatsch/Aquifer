import Observation

/// Runs a mutation and holds its ``MutationState`` for a view. Errors are caught here, on the main
/// actor, so `any Error` never crosses an isolation boundary.
@MainActor
@Observable
final class MutationObserver<M: Mutation> {
    private(set) var state = MutationState<M.Value>()

    @ObservationIgnored private var mutation: M?
    @ObservationIgnored private var client: QueryClient?

    init() {}

    func configure(_ mutation: M, client: QueryClient) {
        self.mutation = mutation
        self.client = client
    }

    @discardableResult
    func run(_ variables: M.Variables) async throws -> M.Value {
        guard let mutation, let client else {
            fatalError("Mutation run before configuration. This is an internal Aquifer error.")
        }

        state.isRunning = true
        state.error = nil
        defer { state.isRunning = false }

        do {
            let value = try await mutation.mutate(variables)
            state.value = value
            await mutation.onSuccess(value, client)
            return value
        } catch {
            state.error = error
            throw error
        }
    }
}
