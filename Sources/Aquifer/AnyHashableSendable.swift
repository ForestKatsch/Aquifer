/// `Sendable` `AnyHashable`. The stdlib's isn't `Sendable`, and `any Hashable & Sendable` isn't
/// itself `Hashable`, so neither can key the cache across the actor boundary. This bridges both.
struct AnyHashableSendable: Hashable, Sendable {
    let base: any Hashable & Sendable

    init(_ base: some Hashable & Sendable) {
        if let base = base as? AnyHashableSendable {
            self = base
        } else {
            self.base = base
        }
    }

    static func == (lhs: AnyHashableSendable, rhs: AnyHashableSendable) -> Bool {
        AnyHashable(lhs.base) == AnyHashable(rhs.base)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(AnyHashable(base))
    }
}
