// View models the CLI prints. They are the `--json` output contract: keys are explicit and
// stable, values are strings, numbers, booleans, arrays, or objects. Adding a field is fine;
// renaming or removing one breaks scripts that read the output.

/// The result of `arya init`.
struct InitReport: Codable, Sendable, Equatable {
    /// `created` for a new home, `existing` when the home was already set up.
    enum Status: String, Codable, Sendable { case created, existing }

    let home: String
    let status: Status

    enum CodingKeys: String, CodingKey { case home, status }
}

/// A steward's lifecycle state.
enum StewardState: String, Codable, Sendable {
    /// Defined, rehearsing, not yet allowed to take live triggers.
    case draft
    case ready
    case paused
    case retired
}

/// One row of `arya steward list`.
struct StewardRow: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let state: StewardState
    let charterVersion: Int
    let pendingApprovals: Int
    /// The id of the most recent run, if any.
    let lastRun: String?

    enum CodingKeys: String, CodingKey {
        case id, name, state, charterVersion, pendingApprovals, lastRun
    }
}

/// `arya steward show` and `arya steward create`.
struct StewardDetail: Codable, Sendable, Equatable {
    let summary: StewardRow
    let outcome: String
    /// The success metric, rendered for people: `routed_within_1h (ratio, up, target 0.95)`.
    /// Charter details are `nil` or empty when the facade does not expose the charter.
    let metric: String?
    let guardrails: [String]
    /// Binding ids: `inbox`, `person:alex`.
    let bindings: [String]
    /// Trigger descriptions: `manual`, `every 900s`.
    let triggers: [String]
    let adapter: String?
    let effort: String?

    enum CodingKeys: String, CodingKey {
        case summary, outcome, metric, guardrails, bindings, triggers, adapter, effort
    }
}

/// What the runtime did with one proposed action.
enum ActionDisposition: String, Codable, Sendable {
    /// No disposition recorded yet.
    case proposed
    case executed
    /// Held for approval; see `ActionOutcome.approval`.
    case held
    case rejected
    case failed
}

/// One proposed action in a run report.
struct ActionOutcome: Codable, Sendable, Equatable {
    let id: String
    let kind: String
    let target: String
    let disposition: ActionDisposition
    /// The approval id when the action is held.
    let approval: String?

    enum CodingKeys: String, CodingKey { case id, kind, target, disposition, approval }
}

/// The result of `arya run`.
struct RunReport: Codable, Sendable, Equatable {
    let run: String
    let steward: String
    /// `completed`, `failed`, or `stopped`.
    let status: String
    let summary: String
    let decisions: [String]
    let actions: [ActionOutcome]

    enum CodingKeys: String, CodingKey { case run, steward, status, summary, decisions, actions }
}

/// An approval's state.
enum ApprovalState: String, Codable, Sendable {
    case pending, granted, denied, expired
}

/// One row of `arya approvals`, and the result of `arya approve` and `arya deny`.
struct ApprovalRow: Codable, Sendable, Equatable {
    let id: String
    let steward: String
    let run: String
    let action: String
    let target: String
    let rationale: String
    let state: ApprovalState
    /// RFC 3339 timestamp from the ledger.
    let requestedAt: String

    enum CodingKeys: String, CodingKey {
        case id, steward, run, action, target, rationale, state, requestedAt
    }
}

/// One row of `arya ledger tail`.
struct EventSummary: Codable, Sendable, Equatable {
    let seq: Int
    let at: String
    let type: String
    /// `kind:id`, such as `human:local` or `steward:st_triage`.
    let actor: String
    let steward: String?
    let run: String?

    enum CodingKeys: String, CodingKey { case seq, at, type, actor, steward, run }
}

/// The result of `arya ledger verify`.
struct VerifyReport: Codable, Sendable, Equatable {
    /// Where the chain first breaks.
    struct Break: Codable, Sendable, Equatable {
        let seq: Int
        let reason: String

        enum CodingKeys: String, CodingKey { case seq, reason }
    }

    let isValid: Bool
    let events: Int
    let firstBreak: Break?

    enum CodingKeys: String, CodingKey {
        case isValid = "ok"
        case events, firstBreak
    }
}
