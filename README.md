# Aquifer

Data fetching and caching for Swift and SwiftUI. Like TanStack Query, but native.

- Queries are plain Swift types. Identity is the cache key.
- Declarative loading and error states in SwiftUI.
- Stale-while-revalidate caching with per-query TTL.
- Automatic request deduplication.
- Strict-concurrency clean. No `@unchecked Sendable`, no `nonisolated(unsafe)`.

Swift 5.9+ (Swift 6 mode optional) · iOS 17+ · macOS 14+ · visionOS 1+

## Define a query

Instances of `Query` are the value. Its identity is the key. `fetch()` is the request.

```swift
struct TodoByID: Query {
    let id: Int

    func fetch() async throws -> Todo {
        try await api.get("/todos/\(id)")
    }
}
```

`TodoByID(id: 5)` is the cache key. Same value means same cache entry and one request.

## Read it in a view

`QueryView` for a single piece of UI. `loading` is optional, defaults to a spinner.

```swift
QueryView(TodoByID(id: 5)) { todo in
    Text(todo.title)
} error: { error in
    ErrorView(error)
}
```

`@Fetch` when you want the state yourself.

```swift
struct TodoDetail: View {
    @Fetch(TodoByID(id: 5)) private var todo

    var body: some View {
        if let todo = todo.value { TodoCard(todo) }
        if todo.isFetching { RefreshDot() }
        if let error = todo.error { ErrorBanner(error) }
    }
}
```

```swift
struct QueryState<Value: Sendable> {
    var value: Value?    // last success, survives a refetch
    var error: Error?
    var isFetching: Bool
}
```

`value != nil && isFetching` is the stale-while-revalidate case: old data on screen, new data loading.

## Read several at once

Resolve as a unit. Loading if any is loading, failed if any fails, done when all succeed.

```swift
QueryView(UserByID(id: 1), PostsByUser(id: 1)) { user, posts in
    ProfileHeader(user)
    PostList(posts)
} error: { error in
    ErrorView(error)
}
```

## The cache

A `QueryClient` actor holds the cache, dedupes requests, and runs stale-while-revalidate. Create one and inject it at the root.

```swift
@main
struct MyApp: App {
    @State private var client = QueryClient(options: QueryOptions(
        staleTime: .seconds(5),       // cache stays fresh this long
        gcTime: .seconds(300),        // evict this long after last use
        refetchOnForeground: true     // refetch stale queries when the app returns to foreground
    ))

    var body: some Scene {
        WindowGroup {
            ContentView().queryClient(client)
        }
    }
}
```

The client sets the defaults. If needed, queries can override them for itself:

```swift
extension TodoByID {
    var staleTime: Duration? { .seconds(30) }
}
```

Invalidate cached queries by type or predicate. The value is kept; on-screen queries refetch in the background, the rest refetch next time they're shown.

```swift
await client.invalidate(TodoByID.self)
await client.invalidate { (q: TodoByID) in q.id == 5 }
```

`remove` drops the value instead, so on-screen views will lose their cached data and will revert to a cold refetch. `removeAll` clears everything, e.g. on logout.

```swift
await client.remove(TodoByID.self)
await client.removeAll()
```

## Mutations

A one-shot side effect — create, update, delete. Define it like a query, with `mutate` instead of `fetch`. `onSuccess` is optional and is where you refresh affected queries.

```swift
struct AddTodo: Mutation {
    func mutate(_ title: String) async throws -> Todo {
        try await api.post("/todos", ["title": title])
    }
    func onSuccess(_ todo: Todo, _ client: QueryClient) async {
        await client.invalidate(TodoList.self)
    }
}
```

Trigger it from a view with `@Mutate`. The handle is callable, and carries `isRunning` / `value` / `error`.

```swift
struct AddTodoButton: View {
    @Mutate(AddTodo()) private var add

    var body: some View {
        Button("Add") {
            Task { try? await add("Buy milk") }
        }
        .disabled(add.isRunning)
    }
}
```
