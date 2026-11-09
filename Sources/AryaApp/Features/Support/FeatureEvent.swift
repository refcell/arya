import Foundation

/// Who caused an event, mirroring the ledger's `actor` field.
struct FeatureActor: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case human, steward, adapter, system
    }

    var kind: Kind
    var id: String

    /// The person using this app. Every write the app makes is attributed to it.
    static let localUser = FeatureActor(kind: .human, id: "local")
}

/// One ledger event as the feature views read it: the envelope from ARCHITECTURE.md with the
/// payload as untyped JSON. Replaced by the facade's event type once it lands.
struct FeatureEvent: Identifiable, Hashable, Sendable {
    var seq: Int
    var id: String
    var at: Date
    var steward: String?
    var run: String?
    var actor: FeatureActor
    var type: String
    var payload: FeatureJSON
    var hash: String = ""
}
