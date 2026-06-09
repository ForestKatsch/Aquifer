/// Cache identity: type plus value, so two query types can't collide even if their hashes match.
struct CacheKey: Hashable, Sendable {
    let typeID: ObjectIdentifier
    let value: AnyHashableSendable

    init<Q: Query>(_ query: Q) {
        self.typeID = ObjectIdentifier(Q.self)
        self.value = AnyHashableSendable(query)
    }
}
