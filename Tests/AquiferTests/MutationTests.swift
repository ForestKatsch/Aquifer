import Testing
@testable import Aquifer

private struct Increment: Mutation {
    func mutate(_ by: Int) async throws -> Int { by + 1 }
}

private struct Thing: Query {
    let id: Int
    func fetch() async throws -> Int { id }
}

private struct Touch: Mutation {
    func mutate(_ variables: Void) async throws -> Bool { true }
    func onSuccess(_ value: Bool, _ client: QueryClient) async {
        await client.invalidate(Thing.self)
    }
}

private struct Failing: Mutation {
    struct Boom: Error {}
    func mutate(_ variables: Void) async throws -> Int { throw Boom() }
}

@MainActor
@Suite("MutationObserver", .serialized)
struct MutationTests {
    @Test("a run returns its value and records it in state")
    func runUpdatesState() async throws {
        let observer = MutationObserver<Increment>()
        observer.configure(Increment(), client: QueryClient())

        let result = try await observer.run(5)
        #expect(result == 6)
        #expect(observer.state.value == 6)
        #expect(observer.state.error == nil)
        #expect(observer.state.isRunning == false)
    }

    @Test("onSuccess can invalidate queries")
    func onSuccessInvalidates() async throws {
        let client = QueryClient(options: QueryOptions(staleTime: .seconds(1000)))
        _ = try await client.fetch(Thing(id: 1))
        #expect(await client.cachedValue(for: Thing(id: 1)).isStale == false)

        let observer = MutationObserver<Touch>()
        observer.configure(Touch(), client: client)
        _ = try await observer.run(())

        #expect(await client.cachedValue(for: Thing(id: 1)).isStale == true)
    }

    @Test("a failed run records the error")
    func failureRecordsError() async {
        let observer = MutationObserver<Failing>()
        observer.configure(Failing(), client: QueryClient())

        await #expect(throws: Failing.Boom.self) {
            try await observer.run(())
        }
        #expect(observer.state.error is Failing.Boom)
        #expect(observer.state.isRunning == false)
    }
}
