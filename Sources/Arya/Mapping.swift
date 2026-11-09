import AryaCore
import AryaLedger
import AryaRuntime
import Foundation

// Maps runtime projections and ledger events into the facade's read models.

extension Timestamp {
    var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

extension StewardSummary {
    init(_ record: StewardRecord) {
        let status: Status =
            switch record.status {
            case .active: .active
            case .paused: .paused
            case .retired: .retired
            }
        self.init(
            id: record.id.rawValue, name: record.charter.name, outcome: record.charter.outcome,
            charterVersion: record.version, status: status, ready: record.ready)
    }
}

extension RunSummary {
    init(_ record: RunRecord) {
        let status: Status =
            switch record.status {
            case .running: .running
            case .finished: .finished
            case .failed: .failed
            }
        self.init(
            id: record.id.rawValue, steward: record.steward.rawValue,
            parent: record.parent?.rawValue, trigger: record.trigger,
            charterVersion: record.charterVersion, status: status, endStatus: record.endStatus,
            failureReason: record.failureReason, summary: record.summary,
            startedAt: record.startedAt.date, endedAt: record.endedAt?.date,
            costMicros: Int(record.costMicros), actionsProposed: record.actions)
    }
}

extension ApprovalSummary {
    init(_ record: ApprovalRecord) {
        let status: Status =
            switch record.status {
            case .pending: .pending
            case .granted: .granted
            case .denied: .denied
            case .expired: .expired
            }
        var kind = Kind.action
        var text = ""
        var action: ProposedAction?
        switch record.subject {
        case .action(let proposed):
            action = proposed
            text = proposed.rationale ?? ""
        case .question(let question):
            kind = .question
            text = question
        }
        self.init(
            id: record.id.rawValue, kind: kind, steward: record.steward.rawValue,
            run: record.run.rawValue, actionKind: action?.kind, binding: action?.binding,
            target: action?.target, text: text, to: record.to, status: status,
            decidedBy: record.decidedBy?.id, requestedAt: record.requestedAt.date)
    }
}

extension LedgerEntry {
    init(_ event: Event) throws {
        self.init(
            seq: Int(event.seq), id: event.id.rawValue, at: event.at.date,
            type: event.type.rawValue,
            steward: event.steward?.rawValue, run: event.run?.rawValue,
            actorKind: event.actor.kind.rawValue, actorID: event.actor.id,
            payload: try CanonicalJSON.string(event.payload))
    }
}
