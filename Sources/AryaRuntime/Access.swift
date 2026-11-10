import AryaAdapters
import AryaCore
import AryaLedger

// Access grants in the run path (decision 0064). The workspace owns grant data (teams, and
// view/approve/use grants on stewards, connections, and tools) and hands the runtime an
// `AccessGrants` value through an `AccessSource`. The runtime enforces two of them:
// - `use`: an action a live run proposes on behalf of a person (the sender of a message, or the
//   person who started the run) that calls a connection needs a use grant covering it, for the
//   person or one of their teams. Without one it is rejected (`action.rejected`, reason
//   `access:use`) and raised as a finding, deduped while open.
// - `approve`: deciding an action approval needs an approve grant covering it; otherwise
//   `approval.refused` is recorded (rule `grant:approve`) and the decision is refused.
// No source, or a source that returns nil, enforces nothing: homes without grants work as
// before. The local owner (`local`) is never limited.

/// What a grant lets its subject do.
public enum AccessLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case view
    case approve
    case use
}

/// One grant: `subject` may `level` on `resource`.
public struct AccessGrant: Sendable, Hashable, Codable {
    /// `person:<id>` or `team:<id>`.
    public var subject: String
    public var level: AccessLevel
    /// `steward:<id>` (everything the steward does), `connection:<binding id>` (every tool of
    /// that connection), `tool:<binding id>.<action kind>` (one tool), or `*`.
    public var resource: String

    public init(subject: String, level: AccessLevel, resource: String) {
        self.subject = subject
        self.level = level
        self.resource = resource
    }
}

/// The grants and teams in force, as the workspace supplies them.
public struct AccessGrants: Sendable, Hashable, Codable {
    public var grants: [AccessGrant]
    /// Team id (`team:<id>`) to member ids (`person:<id>`).
    public var teams: [String: [String]]

    public init(grants: [AccessGrant] = [], teams: [String: [String]] = [:]) {
        self.grants = grants
        self.teams = teams
    }

    /// The grant that lets `person` do `level` on any of `resources`, or nil.
    public func grant(_ level: AccessLevel, person: String, on resources: [String])
        -> AccessGrant?
    {
        let who = Access.person(person)
        let subjects = Set([who] + teams.filter { $0.value.map(Access.person).contains(who) }.keys)
        let wanted = Set(resources + ["*"])
        return grants.first {
            $0.level == level && subjects.contains($0.subject) && wanted.contains($0.resource)
        }
    }

    /// Subjects holding `level` on any of `resources`, for a refusal's "only … may".
    public func holders(_ level: AccessLevel, on resources: [String]) -> [String] {
        let wanted = Set(resources + ["*"])
        var out: [String] = []
        for grant in grants where grant.level == level && wanted.contains(grant.resource) {
            if !out.contains(grant.subject) { out.append(grant.subject) }
        }
        return out
    }
}

/// The grants in force for a steward's runs, or nil when nothing is enforced.
public typealias AccessSource = @Sendable (StewardID) async throws -> AccessGrants?

/// Access checks.
public enum Access {
    /// The action rejection reason for a missing use grant.
    public static let useReason = "access:use"
    /// The `approval.refused` rule for a missing approve grant.
    public static let approveRule = "grant:approve"

    /// `person:<id>` for a person id given with or without the prefix.
    public static func person(_ id: String) -> String {
        id.hasPrefix("person:") || id.hasPrefix("team:") ? id : "person:" + id
    }

    /// True for the local owner, whom grants never limit.
    public static func isOwner(_ id: String) -> Bool {
        id == "local" || id == "person:local" || id == "human:local"
    }

    /// The person a live run acts on behalf of: a message's sender, else the person who
    /// started it; nil for the steward acting on its own (schedules, triggers, the owner).
    public static func principal(of request: RunRequest) -> String? {
        if request.input.kind == .message {
            for attachment in request.input.attachments {
                if let from = attachment["from"]?.stringValue, !isOwner(from) {
                    return person(from)
                }
            }
        }
        if request.actor.kind == "human", !isOwner(request.actor.id) {
            return person(request.actor.id)
        }
        return nil
    }

    /// The resources an action touches, broadest first: its steward, its connection, its tool.
    /// Empty for an action that calls no connection (a routine, a message to a person with no
    /// relay).
    public static func resources(
        of action: ProposedAction, steward: StewardID, charter: Charter
    ) -> [String] {
        guard let id = action.binding, let binding = charter.binding(id) else { return [] }
        var connection = binding
        if binding.kind == .person {
            guard let relay = ActionDispatcher.relay(action, charter) else { return [] }
            connection = relay
        }
        return [
            "steward:\(steward.rawValue)", "connection:\(connection.id)",
            "tool:\(connection.id).\(action.kind)",
        ]
    }

    /// The plain reason `person` may not use `action`, or nil when a grant covers it.
    public static func refusal(
        _ grants: AccessGrants, person: String, action: ProposedAction, charter: Charter
    ) -> String? {
        guard !isOwner(person) else { return nil }
        let resources = resources(of: action, steward: charter.id, charter: charter)
        guard resources.count == 3, grants.grant(.use, person: person, on: resources) == nil
        else { return nil }
        let connection = String(resources[1].dropFirst("connection:".count))
        return "\(person) has no use grant for \(action.kind) on \(connection)"
    }
}
