import AryaCore

/// `approval.requested`: an `ask` action or a `host/ask` question waits for a person.
/// `{approval, kind: "action", action, to, expiresAt?}` or
/// `{approval, kind: "question", question, to, expiresAt?}`.
public struct ApprovalRequested: EventPayload {
    public static let type = EventType.approvalRequested

    public enum Kind: String, Sendable, Hashable, Codable { case action, question }

    public var approval: ApprovalID
    public var kind: Kind
    public var action: ProposedAction?
    public var question: String?
    /// Who should decide: `local` or a person binding id. Advisory (single user).
    public var to: String
    public var expiresAt: Timestamp?

    /// A held action.
    public init(
        approval: ApprovalID, action: ProposedAction, to: String = "local",
        expiresAt: Timestamp? = nil
    ) {
        self.approval = approval
        kind = .action
        self.action = action
        self.to = to
        self.expiresAt = expiresAt
    }

    /// A question from a run.
    public init(
        approval: ApprovalID, question: String, to: String = "local", expiresAt: Timestamp? = nil
    ) {
        self.approval = approval
        kind = .question
        self.question = question
        self.to = to
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case approval, kind, action, question, to, expiresAt }
}

/// `approval.granted`.
public struct ApprovalGranted: EventPayload {
    public static let type = EventType.approvalGranted
    public var approval: ApprovalID
    public var note: String?

    public init(approval: ApprovalID, note: String? = nil) {
        self.approval = approval
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case approval, note }
}

/// `approval.denied`.
public struct ApprovalDenied: EventPayload {
    public static let type = EventType.approvalDenied
    public var approval: ApprovalID
    public var note: String?

    public init(approval: ApprovalID, note: String? = nil) {
        self.approval = approval
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case approval, note }
}

/// `approval.expired`.
public struct ApprovalExpired: EventPayload {
    public static let type = EventType.approvalExpired
    public var approval: ApprovalID
    public var note: String?

    public init(approval: ApprovalID, note: String? = nil) {
        self.approval = approval
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case approval, note }
}
