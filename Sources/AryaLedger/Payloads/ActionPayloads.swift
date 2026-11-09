import AryaCore

/// `action.proposed`: an action from a run's result and how the charter's policy classified
/// it. `auto` is followed by `action.executed` or `action.failed`, `ask` by
/// `approval.requested`, `deny` by `action.rejected`.
public struct ActionProposed: EventPayload {
    public static let type = EventType.actionProposed
    public var action: ProposedAction
    public var disposition: PolicyDecision
    /// The classifier's reason, for example `rule:label` or `not_allowed:tracker.close`.
    public var reason: String

    public init(action: ProposedAction, disposition: PolicyDecision, reason: String) {
        self.action = action
        self.disposition = disposition
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case action, disposition, reason }
}

/// `action.executed`: the executor's output, a recorded input for replay.
public struct ActionExecuted: EventPayload {
    public static let type = EventType.actionExecuted
    /// The action id within its run (the envelope's `run`).
    public var action: String
    /// Set when a granted approval released the action.
    public var approval: ApprovalID?
    public var output: JSONValue?

    public init(action: String, approval: ApprovalID? = nil, output: JSONValue? = nil) {
        self.action = action
        self.approval = approval
        self.output = output
    }

    enum CodingKeys: String, CodingKey { case action, approval, output }
}

/// `action.failed`: the executor failed.
public struct ActionFailed: EventPayload {
    public static let type = EventType.actionFailed
    public var action: String
    public var approval: ApprovalID?
    public var output: JSONValue?
    public var error: String

    public init(
        action: String, approval: ApprovalID? = nil, output: JSONValue? = nil, error: String
    ) {
        self.action = action
        self.approval = approval
        self.output = output
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case action, approval, output, error }
}

/// `action.rejected`: the policy said `deny`, or a person denied the approval, or it expired.
public struct ActionRejected: EventPayload {
    public static let type = EventType.actionRejected
    public var action: String
    public var approval: ApprovalID?
    public var reason: String

    public init(action: String, approval: ApprovalID? = nil, reason: String) {
        self.action = action
        self.approval = approval
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case action, approval, reason }
}
