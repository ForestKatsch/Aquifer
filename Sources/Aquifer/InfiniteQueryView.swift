import SwiftUI

/// A `List`-backed view over an ``InfiniteQuery`` that paginates as the user scrolls. It flattens
/// each page into `Identifiable` rows, renders one `row` per item, and calls `fetchNextPage()` when
/// the last row appears.
///
/// Before the first page arrives it shows `loading` (or `error` if that first load failed). Once
/// there are pages it shows the list with a `footer` underneath — by default a spinner while the
/// next page loads. `loading` and `footer` have defaults; `items`, `row`, and `error` are required.
///
/// ```swift
/// InfiniteQueryView(Feed()) { page in page.items } row: { item in
///     FeedRow(item)
/// } error: { error in
///     ErrorView(error)
/// }
/// ```
public struct InfiniteQueryView<
    Q: InfiniteQuery, Item: Identifiable, Row: View, ErrorContent: View, Loading: View, Footer: View
>: View {
    private var fetch: InfiniteFetch<Q>
    private let items: (Q.Page) -> [Item]
    private let row: (Item) -> Row
    private let errorContent: (Error) -> ErrorContent
    private let loading: () -> Loading
    private let footer: (InfiniteQueryState<Q.Page>) -> Footer

    public init(
        _ query: Q,
        items: @escaping (Q.Page) -> [Item],
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder error: @escaping (Error) -> ErrorContent,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder footer: @escaping (InfiniteQueryState<Q.Page>) -> Footer
    ) {
        self.fetch = InfiniteFetch(query)
        self.items = items
        self.row = row
        self.errorContent = error
        self.loading = loading
        self.footer = footer
    }

    public var body: some View {
        let handle = fetch.wrappedValue
        let state = handle.state
        if state.pages.isEmpty {
            if let error = state.error {
                errorContent(error)
            } else {
                loading()
            }
        } else {
            let rows = state.pages.flatMap(items)
            List {
                ForEach(rows) { item in
                    row(item)
                        .onAppear {
                            if item.id == rows.last?.id {
                                Task { await handle.fetchNextPage() }
                            }
                        }
                }
                footer(state)
            }
        }
    }
}

public extension InfiniteQueryView
where Loading == ProgressView<EmptyView, EmptyView>, Footer == DefaultInfinitePageFooter {
    /// Defaults `loading` to a `ProgressView` and `footer` to a centered spinner shown while the next
    /// page loads.
    init(
        _ query: Q,
        items: @escaping (Q.Page) -> [Item],
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder error: @escaping (Error) -> ErrorContent
    ) {
        self.init(
            query,
            items: items,
            row: row,
            error: error,
            loading: { ProgressView() },
            footer: { DefaultInfinitePageFooter(isFetchingNextPage: $0.isFetchingNextPage) }
        )
    }
}

/// The default ``InfiniteQueryView`` footer: a centered spinner while the next page is loading,
/// nothing otherwise.
public struct DefaultInfinitePageFooter: View {
    let isFetchingNextPage: Bool

    public var body: some View {
        if isFetchingNextPage {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }
}
