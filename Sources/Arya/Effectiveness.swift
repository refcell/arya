import AryaCore
import AryaRuntime
import Foundation

// What worked (runtime decision 0054): each action kind's follow-up check results and the
// metric change credited to it, for the recap and the plan.

/// How one action kind has worked for a steward.
public struct EffectSummary: Sendable, Hashable, Codable {
    public var kind: String
    public var executed: Int
    public var failed: Int
    /// Only drafted (dry runs): nothing was sent.
    public var drafted: Int
    public var resolved: Int
    public var reopened: Int
    /// Checks not settled yet.
    public var pending: Int
    /// Resolved among settled checks (0...1), when any settled.
    public var successRate: Double?
    /// Metric change per credited action, positive is good, when any.
    public var creditPerAction: Double?
    /// One line, for example `label: 4 of 5 resolved, metric +0.020 per action (6 executed)`.
    public var line: String
}

/// One follow-up check of an executed action.
public struct CheckSummary: Sendable, Hashable, Codable {
    public var run: String
    public var action: String
    public var kind: String
    public var target: String
    public var attempt: Int
    public var status: String
    public var note: String?
    public var at: Date
}

extension Workspace {
    /// Each action kind `steward` executed, with its check results and metric credit.
    public func effectiveness(steward: String) async throws -> [EffectSummary] {
        let id = try await existing(steward).id
        return try Effectiveness.of(id, in: try await sink.events(from: 1)).map {
            EffectSummary(
                kind: $0.kind, executed: $0.executed, failed: $0.failed, drafted: $0.drafted,
                resolved: $0.resolved,
                reopened: $0.reopened, pending: $0.pending, successRate: $0.successRate,
                creditPerAction: $0.creditPerAction, line: $0.line)
        }
    }

    /// `steward`'s follow-up checks, newest first, at most `limit`.
    public func checks(steward: String, limit: Int = 20) async throws -> [CheckSummary] {
        let id = try await existing(steward).id
        let events = try await sink.events(from: 1).filter {
            $0.draft.steward == id && $0.type == OutcomeEventType.checked.rawValue
        }
        return events.reversed().prefix(limit).compactMap { event in
            guard let run = event.draft.run,
                let body = try? CanonicalJSON.decode(
                    ActionChecked.self, from: try CanonicalJSON.encode(event.payload))
            else { return nil }
            return CheckSummary(
                run: run.rawValue, action: body.action, kind: body.kind, target: body.target,
                attempt: body.attempt, status: body.status, note: body.note, at: event.at.date)
        }
    }
}
