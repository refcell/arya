import Arya
import Foundation

// Feature workspace reads owned by connect (People): conversations.
// One file per lane so lanes stop colliding in FeatureWorkspace.swift; add requirements and
// their defaults here.

/// One message in a person's thread: theirs (inbound) or the steward's delivery (outbound).
struct FeatureConversationEntry: Hashable, Sendable {
    var seq: Int
    var inbound: Bool
    /// `ask`, `correct`, or `handoff`, for inbound messages.
    var intent: String?
    var text: String?
    /// The run that sent an outbound entry.
    var run: String?
}

/// A note a steward keeps about a person (`Workspace.personMemory`, decision 0061).
struct FeaturePersonNote: Hashable, Sendable, Identifiable {
    var id: String
    /// The steward that keeps it, or `shared`.
    var steward: String
    var text: String
    var author: String
    var run: String?
    var tags: [String]
    var seq: Int
}

/// A newer routine version a steward can take (`Workspace.routineUpgrades`, decision 0062).
struct FeatureRoutineUpgrade: Hashable, Sendable {
    var steward: String
    var name: String
    var from: String
    var to: String
    /// The steward it follows, which promoted `to`.
    var source: String
    /// The upgrade is already proposed and waits on its gate or a person.
    var pending: Bool
}

/// The connect lane's reads; `FeatureWorkspace` inherits them.
protocol FeatureConnectReads: Sendable {
    /// One person's conversation with a steward, oldest first (`Workspace.conversation`).
    func conversation(steward: String, person: String) async throws -> [FeatureConversationEntry]
    /// Adapter profile labels by profile id (`Workspace.adapterLabels`).
    func adapterLabels() async throws -> [String: String]
    /// What stewards remember about a person (`Workspace.personMemory`).
    func personMemory(person: String) async throws -> [FeaturePersonNote]
    /// Routine upgrades available across stewards (`Workspace.routineUpgrades`).
    func routineUpgrades() async throws -> [FeatureRoutineUpgrade]
}

extension FeatureConnectReads {
    /// Workspaces without a conversation read report it unavailable; People then folds the
    /// ledger itself.
    func conversation(steward: String, person: String) async throws -> [FeatureConversationEntry] {
        throw FeatureReadError.unavailable("conversation")
    }

    func adapterLabels() async throws -> [String: String] { [:] }

    func personMemory(person: String) async throws -> [FeaturePersonNote] {
        throw FeatureReadError.unavailable("person memory")
    }

    func routineUpgrades() async throws -> [FeatureRoutineUpgrade] { [] }
}
