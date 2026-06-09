import SwiftUI

private struct QueryClientKey: EnvironmentKey {
    static let defaultValue: QueryClient? = nil
}

extension EnvironmentValues {
    var queryClient: QueryClient? {
        get { self[QueryClientKey.self] }
        set { self[QueryClientKey.self] = newValue }
    }
}

public extension View {
    /// The ``QueryClient`` this subtree uses. No default — reading a query without one traps.
    func queryClient(_ client: QueryClient) -> some View {
        environment(\.queryClient, client)
    }
}
