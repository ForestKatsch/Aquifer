import Testing
@testable import Aquifer

private struct IntQuery: Query {
    let id: Int
    func fetch() async throws -> Int { id }
}

private struct StringQuery: Query {
    let key: String
    let fail: Bool
    func fetch() async throws -> String {
        if fail { throw Boom() }
        return key.uppercased()
    }
    struct Boom: Error {}
}

@MainActor
@Suite("MultiQueryObserver")
struct MultiQueryTests {
    // Exercises the parameter-pack combination logic directly. The observer drives off a client
    // and the main run loop, so we poll briefly for the async load to settle.

    private func settle<each Q: Query>(
        _ observer: MultiQueryObserver<repeat each Q>
    ) async {
        for _ in 0..<50 {
            if !observer.state.isFetching, observer.state.value != nil || observer.state.error != nil {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("combined value is present only when all succeed")
    func allSucceed() async {
        let client = QueryClient()
        let observer = MultiQueryObserver<IntQuery, StringQuery>()
        observer.start(IntQuery(id: 7), StringQuery(key: "hi", fail: false), client: client)
        await settle(observer)

        let value = observer.state.value
        #expect(value?.0 == 7)
        #expect(value?.1 == "HI")
        #expect(observer.state.error == nil)
    }

    @Test("one failure fails the whole group")
    func oneFails() async {
        let client = QueryClient()
        let observer = MultiQueryObserver<IntQuery, StringQuery>()
        observer.start(IntQuery(id: 1), StringQuery(key: "x", fail: true), client: client)
        await settle(observer)

        #expect(observer.state.value == nil)
        #expect(observer.state.error is StringQuery.Boom)
    }
}
