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

/// The connect lane's reads; `FeatureWorkspace` inherits them.
protocol FeatureConnectReads: Sendable {
    /// One person's conversation with a steward, oldest first (`Workspace.conversation`).
    func conversation(steward: String, person: String) async throws -> [FeatureConversationEntry]
}

extension FeatureConnectReads {
    /// Workspaces without a conversation read report it unavailable; People then folds the
    /// ledger itself.
    func conversation(steward: String, person: String) async throws -> [FeatureConversationEntry] {
        throw FeatureReadError.unavailable("conversation")
    }
}
