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
        title = Self.title(summary: record.summary, input: record.input)
    }

    /// The summary, else the input's first non-empty line, trimmed to `limit` characters at a
    /// word boundary when one is near.
    static func title(summary: String?, input: String, limit: Int = 60) -> String {
        let source =
            [summary ?? "", input].first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? ""
        let line =
            source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard line.count > limit else { return line }
        let cut = line.prefix(limit - 1)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        let kept = word.count >= limit / 2 ? word : cut
        return kept.trimmingCharacters(in: .whitespaces) + "\u{2026}"
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
        if let params = action?.params, params != .null {
            self.params = try? CanonicalJSON.string(params)
            content = Self.content(params)
        }
    }

    /// Params as text: a `body`, `text`, or `message` string verbatim, else sorted
    /// `key: value` lines (strings bare, other values as canonical JSON).
    static func content(_ params: JSONValue) -> String? {
        for key in ["body", "text", "message"] {
            if let text = params[key]?.stringValue { return text }
        }
        guard case .object(let members) = params else {
            return params.stringValue ?? (try? CanonicalJSON.string(params))
        }
        return members.keys.sorted().map { key in
            let value = members[key] ?? .null
            return "\(key): \(value.stringValue ?? (try? CanonicalJSON.string(value)) ?? "")"
        }.joined(separator: "\n")
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
