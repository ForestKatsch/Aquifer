import SwiftUI

/// Renders one of three states, in priority order: **done** if there's a value, else **error**,
/// else **loading**. With several queries the content closure takes one argument per query and runs
/// only when all succeed. `loading` defaults to a `ProgressView`.
public struct QueryView<each Q: Query, Content: View, ErrorContent: View, Loading: View>: View {
    private var fetch: Fetch<repeat each Q>
    private let content: (repeat (each Q).Value) -> Content
    private let errorContent: (Error) -> ErrorContent
    private let loading: () -> Loading

    public init(
        _ queries: repeat each Q,
        @ViewBuilder content: @escaping (repeat (each Q).Value) -> Content,
        @ViewBuilder error: @escaping (Error) -> ErrorContent,
        @ViewBuilder loading: @escaping () -> Loading
    ) {
        self.fetch = Fetch(repeat each queries)
        self.content = content
        self.errorContent = error
        self.loading = loading
    }

    public var body: some View {
        let state = fetch.wrappedValue
        if let value = state.value {
            content(repeat each value)
        } else if let error = state.error {
            errorContent(error)
        } else {
            loading()
        }
    }
}

public extension QueryView where Loading == ProgressView<EmptyView, EmptyView> {
    init(
        _ queries: repeat each Q,
        @ViewBuilder content: @escaping (repeat (each Q).Value) -> Content,
        @ViewBuilder error: @escaping (Error) -> ErrorContent
    ) {
        self.init(repeat each queries, content: content, error: error, loading: { ProgressView() })
    }
}
