/// A namespaced event type such as `run.decision`. Unknown types decode fine, so newer writers
/// do not break older readers.
public struct EventType: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    /// The part before the first dot, for example `run`.
    public var namespace: Substring { rawValue.prefix { $0 != "." } }

    public var description: String { rawValue }

    public static func < (lhs: EventType, rhs: EventType) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension EventType {
    public static let stewardCreated: EventType = "steward.created"
    public static let stewardCharterUpdated: EventType = "steward.charter.updated"
    public static let stewardReady: EventType = "steward.ready"
    public static let stewardPaused: EventType = "steward.paused"
    public static let stewardResumed: EventType = "steward.resumed"
    public static let stewardRetired: EventType = "steward.retired"
    public static let stewardEffortSet: EventType = "steward.effort.set"

    public static let runStarted: EventType = "run.started"
    public static let runInput: EventType = "run.input"
    public static let runAdapterEvent: EventType = "run.adapter.event"
    public static let runToolCall: EventType = "run.tool.call"
    public static let runToolResult: EventType = "run.tool.result"
    public static let runDecision: EventType = "run.decision"
    public static let runFinished: EventType = "run.finished"
    public static let runFailed: EventType = "run.failed"
    public static let runAbortRequested: EventType = "run.abort.requested"

    public static let actionProposed: EventType = "action.proposed"
    public static let actionExecuted: EventType = "action.executed"
    public static let actionFailed: EventType = "action.failed"
    public static let actionRejected: EventType = "action.rejected"
    public static let actionUndoRequested: EventType = "action.undo.requested"

    public static let approvalRequested: EventType = "approval.requested"
    public static let approvalGranted: EventType = "approval.granted"
    public static let approvalDenied: EventType = "approval.denied"
    public static let approvalExpired: EventType = "approval.expired"
    public static let approvalRefused: EventType = "approval.refused"

    public static let memoryAdded: EventType = "memory.added"
    public static let memoryRetracted: EventType = "memory.retracted"
    public static let routineProposed: EventType = "routine.proposed"
    public static let routinePromoted: EventType = "routine.promoted"
    public static let routineRetired: EventType = "routine.retired"

    public static let casebookImported: EventType = "casebook.imported"
    public static let caseCorrected: EventType = "case.corrected"

    public static let rehearsalStarted: EventType = "rehearsal.started"
    public static let rehearsalCaseScored: EventType = "rehearsal.case.scored"
    public static let rehearsalFinished: EventType = "rehearsal.finished"

    public static let proposalCreated: EventType = "proposal.created"
    public static let proposalGated: EventType = "proposal.gated"
    public static let proposalAccepted: EventType = "proposal.accepted"
    public static let proposalRejected: EventType = "proposal.rejected"
    public static let proposalOverridden: EventType = "proposal.overridden"

    public static let metricRecorded: EventType = "metric.recorded"
    public static let envRead: EventType = "env.read"
    public static let systemRepair: EventType = "system.repair"
    public static let systemStarted: EventType = "system.started"
    public static let systemRetentionSet: EventType = "system.retention.set"
    public static let systemKeyAdded: EventType = "system.key.added"
    public static let systemCheckpoint: EventType = "system.checkpoint"
    public static let systemEncryptionEnabled: EventType = "system.encryption.enabled"
    public static let systemAuditExported: EventType = "system.audit.exported"
    public static let systemRetentionApplied: EventType = "system.retention.applied"

    /// Every known type, in ARCHITECTURE.md order (`steward.resumed` added by decision 0021,
    /// `steward.effort.set` by decision 0026, `system.key.added` and
    /// `system.checkpoint` by the checkpoint note).
    public static let all: [EventType] = [
        stewardCreated, stewardCharterUpdated, stewardReady, stewardPaused, stewardResumed,
        stewardRetired, stewardEffortSet,
        runStarted, runInput, runAdapterEvent, runToolCall, runToolResult, runDecision,
        runFinished, runFailed, runAbortRequested, actionProposed, actionExecuted, actionFailed,
        actionRejected, actionUndoRequested,
        approvalRequested, approvalGranted, approvalDenied, approvalExpired, approvalRefused,
        memoryAdded, memoryRetracted, routineProposed, routinePromoted, routineRetired,
        casebookImported, caseCorrected, rehearsalStarted, rehearsalCaseScored, rehearsalFinished,
        proposalCreated, proposalGated, proposalAccepted, proposalRejected, proposalOverridden,
        metricRecorded, envRead, systemRepair, systemStarted, systemKeyAdded, systemCheckpoint,
        systemRetentionSet, systemEncryptionEnabled, systemAuditExported, systemRetentionApplied,
    ]
}
