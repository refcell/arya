import Foundation

// Read models the facade returns. They are plain values built from ledger projections, so the
// CLI can print them and the app can render them without importing lower modules.

/// A steward as listings show it.
public struct StewardSummary: Sendable, Hashable, Codable, Identifiable {
    /// Lifecycle status.
    public enum Status: String, Sendable, Hashable, Codable {
        /// Takes triggers (live ones only once ready).
        case active
        /// Takes no triggers until resumed.
        case paused
        /// Gone for good; kept for history.
        case retired
    }

    /// Steward id, for example `st_triage`.
    public var id: String
    /// Display name.
    public var name: String
    /// The outcome it owns.
    public var outcome: String
    /// Live charter version, from 1.
    public var charterVersion: Int
    /// Lifecycle status.
    public var status: Status
    /// True once a person marked it ready for live triggers.
    public var ready: Bool

    /// Creates a summary.
    public init(
        id: String, name: String, outcome: String, charterVersion: Int, status: Status,
        ready: Bool
    ) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.charterVersion = charterVersion
        self.status = status
        self.ready = ready
    }
}

/// A run as listings show it.
public struct RunSummary: Sendable, Hashable, Codable, Identifiable {
    /// Where the run is.
    public enum Status: String, Sendable, Hashable, Codable {
        /// Started and not yet finished.
        case running
        /// Finished normally (completed or stopped; see `endStatus`).
        case finished
        /// Failed; see `failureReason`.
        case failed
    }

    /// Run id.
    public var id: String
    /// Steward id.
    public var steward: String
    /// Parent run for crew children, else `nil`.
    public var parent: String?
    /// Trigger kind: `manual`, `schedule`, `message`, `case`, or `join`.
    public var trigger: String
    /// Charter version the run used.
    public var charterVersion: Int
    /// Status.
    public var status: Status
    /// `completed` or `stopped` when finished.
    public var endStatus: String?
    /// `adapter_exited`, `timeout`, `invalid_result`, `budget`, `interrupted`, … when failed.
    public var failureReason: String?
    /// Adapter summary from `run/result`, when there is one.
    public var summary: String?
    /// Start time.
    public var startedAt: Date
    /// End time, once finished or failed.
    public var endedAt: Date?
    /// Cost in micro-dollars, once known.
    public var costMicros: Int
    /// Number of actions proposed.
    public var actionsProposed: Int
    /// A short human title: the result summary, else the input's first line, trimmed to
    /// about 60 characters.
    public var title: String = ""

    /// Creates a summary.
    public init(
        id: String, steward: String, parent: String? = nil, trigger: String,
        charterVersion: Int, status: Status, endStatus: String? = nil,
        failureReason: String? = nil, summary: String? = nil, startedAt: Date,
        endedAt: Date? = nil, costMicros: Int = 0, actionsProposed: Int = 0
    ) {
        self.id = id
        self.steward = steward
        self.parent = parent
        self.trigger = trigger
        self.charterVersion = charterVersion
        self.status = status
        self.endStatus = endStatus
        self.failureReason = failureReason
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.costMicros = costMicros
        self.actionsProposed = actionsProposed
    }
}

extension RunSummary {
    /// Decodes a summary; JSON written before `title` existed gets one from `summary`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            steward: try c.decode(String.self, forKey: .steward),
            parent: try c.decodeIfPresent(String.self, forKey: .parent),
            trigger: try c.decode(String.self, forKey: .trigger),
            charterVersion: try c.decode(Int.self, forKey: .charterVersion),
            status: try c.decode(Status.self, forKey: .status),
            endStatus: try c.decodeIfPresent(String.self, forKey: .endStatus),
            failureReason: try c.decodeIfPresent(String.self, forKey: .failureReason),
            summary: try c.decodeIfPresent(String.self, forKey: .summary),
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            endedAt: try c.decodeIfPresent(Date.self, forKey: .endedAt),
            costMicros: try c.decode(Int.self, forKey: .costMicros),
            actionsProposed: try c.decode(Int.self, forKey: .actionsProposed))
        title =
            try c.decodeIfPresent(String.self, forKey: .title)
            ?? Self.title(summary: summary, input: "")
    }
}

/// An item in the approval queue: a held action or a question from a run.
public struct ApprovalSummary: Sendable, Hashable, Codable, Identifiable {
    /// What is being approved.
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A proposed action held by policy.
        case action
        /// A `host/ask` question from a run.
        case question
    }

    /// Where the approval is.
    public enum Status: String, Sendable, Hashable, Codable {
        /// Waiting for a person.
        case pending
        /// Granted (or answered).
        case granted
        /// Denied.
        case denied
        /// Expired before anyone decided.
        case expired
    }

    /// Approval id.
    public var id: String
    /// Kind.
    public var kind: Kind
    /// Steward id.
    public var steward: String
    /// Run that asked.
    public var run: String
    /// Action kind, for actions.
    public var actionKind: String?
    /// Binding, for actions.
    public var binding: String?
    /// Target, for example `tracker:ISSUE-7`, for actions.
    public var target: String?
    /// The steward's rationale (actions) or the question text (questions).
    public var text: String
    /// Who should decide: `local` or a contact id.
    public var to: String
    /// Status.
    public var status: Status
    /// Who decided, once decided.
    public var decidedBy: String?
    /// When it was requested.
    public var requestedAt: Date
    /// The full proposed content as text, for actions: a `body`, `text`, or `message` param
    /// verbatim, else one `key: value` line per param.
    public var content: String?
    /// The action's params as canonical JSON, for actions with params.
    public var params: String?
    /// The item the run worked on (the run's input text, for example the message it read).
    public var source: String?
    /// The policy verdict that held it, for example `default` or `rule:reply`.
    public var policyRule: String?
    /// The adapter's risk hint for the action (`low`, `medium`, `high`), when it gave one.
    /// Policy, not the hint, decides.
    public var risk: String?
    /// The steward's one-line why for the action, when it gave one.
    public var why: String?

    /// Creates a summary.
    public init(
        id: String, kind: Kind, steward: String, run: String, actionKind: String? = nil,
        binding: String? = nil, target: String? = nil, text: String, to: String = "local",
        status: Status, decidedBy: String? = nil, requestedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.steward = steward
        self.run = run
        self.actionKind = actionKind
        self.binding = binding
        self.target = target
        self.text = text
        self.to = to
        self.status = status
        self.decidedBy = decidedBy
        self.requestedAt = requestedAt
    }
}

/// One ledger event as the ledger table and `arya ledger tail` show it.
public struct LedgerEntry: Sendable, Hashable, Codable, Identifiable {
    /// Position in the ledger, from 1.
    public var seq: Int
    /// Event id.
    public var id: String
    /// Event time.
    public var at: Date
    /// Event type, for example `run.decision`.
    public var type: String
    /// Steward, if any.
    public var steward: String?
    /// Run, if any.
    public var run: String?
    /// `human`, `steward`, `adapter`, or `system`.
    public var actorKind: String
    /// Actor id.
    public var actorID: String
    /// The payload as canonical JSON text.
    public var payload: String

    /// Creates an entry.
    public init(
        seq: Int, id: String, at: Date, type: String, steward: String? = nil,
        run: String? = nil, actorKind: String, actorID: String, payload: String
    ) {
        self.seq = seq
        self.id = id
        self.at = at
        self.type = type
        self.steward = steward
        self.run = run
        self.actorKind = actorKind
        self.actorID = actorID
        self.payload = payload
    }
}

/// The result of verifying the ledger.
public struct LedgerCheck: Sendable, Hashable, Codable {
    /// True when the whole chain verifies.
    public var ok: Bool
    /// Events checked.
    public var events: Int
    /// The first bad `seq`, if any.
    public var firstBadSeq: Int?
    /// What failed, if anything.
    public var detail: String?

    /// Creates a check result.
    public init(ok: Bool, events: Int, firstBadSeq: Int? = nil, detail: String? = nil) {
        self.ok = ok
        self.events = events
        self.firstBadSeq = firstBadSeq
        self.detail = detail
    }
}
