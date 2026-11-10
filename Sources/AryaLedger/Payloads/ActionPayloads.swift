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
    /// The action's resolved risk, when the steward has an autonomy level (decision 0037).
    public var risk: Risk?
    /// The steward's autonomy level that shaped the disposition (decision 0037).
    public var autonomy: Autonomy?

    public init(
        action: ProposedAction, disposition: PolicyDecision, reason: String, risk: Risk? = nil,
        autonomy: Autonomy? = nil
    ) {
        self.action = action
        self.disposition = disposition
        self.reason = reason
        self.risk = risk
        self.autonomy = autonomy
    }

    enum CodingKeys: String, CodingKey { case action, disposition, reason, risk, autonomy }
}

/// `action.executed`: the executor's output, a recorded input for replay.
public struct ActionExecuted: EventPayload {
    public static let type = EventType.actionExecuted
    /// The action id within its run (the envelope's `run`).
    public var action: String
    /// Set when a granted approval released the action.
    public var approval: ApprovalID?
    public var output: JSONValue?
    /// True when the executor only drafted the action and the system was not changed (a dry
    /// run); absent for a real execution.
    public var dryRun: Bool?

    public init(
        action: String, approval: ApprovalID? = nil, output: JSONValue? = nil,
        dryRun: Bool? = nil
    ) {
        self.action = action
        self.approval = approval
        self.output = output
        self.dryRun = dryRun == true ? true : nil
    }

    enum CodingKeys: String, CodingKey { case action, approval, output, dryRun }
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

/// `action.undo.requested`: a person asked to undo an executed action (actor: that person).
/// The compensating action (`compensation`, an action id in the same run) is proposed right
/// after it and goes through policy and approval like any other.
public struct ActionUndoRequested: EventPayload {
    public static let type = EventType.actionUndoRequested
    /// The executed action's id within the run.
    public var action: String
    /// The compensating action's id within the run.
    public var compensation: String
    /// Why, in the person's words.
    public var reason: String?

    public init(action: String, compensation: String, reason: String? = nil) {
        self.action = action
        self.compensation = compensation
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case action, compensation, reason }
}
