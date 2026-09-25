import SwiftUI

/// Renders a query in one of three states, in priority order: **done** if there's a value, else
/// **error**, else **loading**. `loading` defaults to a `ProgressView`.
///
/// ```swift
/// QueryView(TodoByID(id: 5)) { todo in
///     Text(todo.title)
/// } error: { error in
///     ErrorView(error)
/// }
/// ```
///
/// With a `placeholder`, `content` renders it immediately instead of `loading`, then re-renders with
/// the real value once it arrives. See ``Fetch`` for the details.
///
/// For several queries resolved as one unit, use ``MultiQueryView``.
public struct QueryView<Q: Query, Content: View, ErrorContent: View, Loading: View>: View {
    private var fetch: Fetch<Q>
    private let content: (Q.Value) -> Content
    private let errorContent: (Error) -> ErrorContent
    private let loading: () -> Loading

    public init(
        _ query: Q,
        placeholder: Q.Value? = nil,
        @ViewBuilder content: @escaping (Q.Value) -> Content,
        @ViewBuilder error: @escaping (Error) -> ErrorContent,
        @ViewBuilder loading: @escaping () -> Loading
    ) {
        self.fetch = Fetch(query, placeholder: placeholder)
        self.content = content
        self.errorContent = error
        self.loading = loading
    }

    public var body: some View {
        let state = fetch.wrappedValue
        if let value = state.value {
            content(value)
        } else if let error = state.error {
            errorContent(error)
        } else {
            loading()
        }
    }
}

public extension QueryView where Loading == ProgressView<EmptyView, EmptyView> {
    init(
        _ query: Q,
        placeholder: Q.Value? = nil,
        @ViewBuilder content: @escaping (Q.Value) -> Content,
        @ViewBuilder error: @escaping (Error) -> ErrorContent
    ) {
        self.init(
            query, placeholder: placeholder, content: content, error: error, loading: { ProgressView() }
        )
    }
}
