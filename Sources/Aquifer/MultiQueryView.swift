import SwiftUI

/// Renders several queries as one unit, in priority order: **done** if all have values, else
/// **error**, else **loading**. The content closure takes one argument per query and runs only when
/// all succeed. `loading` defaults to a `ProgressView`.
///
/// ```swift
/// MultiQueryView(UserByID(id: 1), PostsByUser(id: 1)) { user, posts in
///     ProfileHeader(user)
///     PostList(posts)
/// } error: { error in
///     ErrorView(error)
/// }
/// ```
///
/// For the common single-query case, use ``QueryView`` — it avoids this type's `each Q` parameter
/// pack, which can crash the Swift runtime while building view metadata on current toolchains.
public struct MultiQueryView<each Q: Query, Content: View, ErrorContent: View, Loading: View>: View {
    private var fetch: FetchMultiple<repeat each Q>
    private let content: (repeat (each Q).Value) -> Content
    private let errorContent: (Error) -> ErrorContent
    private let loading: () -> Loading

    public init(
        _ queries: repeat each Q,
        @ViewBuilder content: @escaping (repeat (each Q).Value) -> Content,
        @ViewBuilder error: @escaping (Error) -> ErrorContent,
        @ViewBuilder loading: @escaping () -> Loading
    ) {
        self.fetch = FetchMultiple(repeat each queries)
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

public extension MultiQueryView where Loading == ProgressView<EmptyView, EmptyView> {
    init(
        _ queries: repeat each Q,
        @ViewBuilder content: @escaping (repeat (each Q).Value) -> Content,
        @ViewBuilder error: @escaping (Error) -> ErrorContent
    ) {
        self.init(repeat each queries, content: content, error: error, loading: { ProgressView() })
    }
}
