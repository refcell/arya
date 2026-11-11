import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation

// Access in the facade (runtime decisions 0064, 0065): teams, view/approve/use grants on
// stewards, connections, and tools, and recent refusals. Changes are ledger events made by a
// person, gated (the owner, or someone who approves everything) and undoable. The workspace
// lane may take this file over; the shapes below are what the app's Settings ▸ Access reads.

/// A team and its members.
public struct AccessTeamSummary: Sendable, Hashable, Codable {
    /// `team:<id>`.
    public var id: String
    public var name: String
    /// `person:<id>` each.
    public var members: [String]
}

/// A grant in force.
public struct AccessGrantSummary: Sendable, Hashable, Codable {
    /// `person:<id>` or `team:<id>`.
    public var subject: String
    /// `view`, `approve`, or `use`.
    public var level: String
    /// `steward:<id>`, `connection:<binding>`, `tool:<binding>.<kind>`, or `*`.
    public var resource: String
    public var by: String
    public var at: Date
    /// The change that made it, for undo.
    public var seq: Int
    /// Uses in the last 7 days (`access.used`), and the newest use.
    public var uses: Int = 0
    public var lastUse: AccessUseSummary? = nil
}

/// One use of a grant: who acted, what the action was, where.
public struct AccessUseSummary: Sendable, Hashable, Codable {
    public var person: String
    public var action: String
    public var target: String?
    public var at: Date
    public var steward: String?
    public var run: String?
    /// True when the grant let the person approve (an approve grant).
    public var approval = false
}

/// Something a grant can cover.
public struct AccessResource: Sendable, Hashable, Codable {
    /// The resource id a grant names.
    public var id: String
    /// `everything`, `steward`, `connection`, or `tool`.
    public var kind: String
    /// A short name: the steward's name, the binding id, `binding.kind`.
    public var label: String
}

/// A refused use or approve.
public struct AccessRefusalSummary: Sendable, Hashable, Codable {
    public var seq: Int
    public var at: Date
    public var steward: String?
    public var run: String?
    public var person: String
    /// `use` or `approve`.
    public var level: String
    public var action: String
    /// The plain reason ("person:sam has no use grant for comment on tracker").
    public var reason: String
    /// What the action touched (`connection:<binding>`, `tool:<binding>.<kind>`, `steward:<id>`),
    /// so a view can name them.
    public var resources: [String] = []
    /// The refused action's target, and what the run was asked (its input), when known.
    public var target: String? = nil
    public var asked: String? = nil
}

/// The latest access change, with whether it can still be undone.
public struct AccessChangeSummary: Sendable, Hashable, Codable {
    public var seq: Int
    /// "Granted use on connection:tracker to team:support" and the like.
    public var text: String
    public var by: String
    public var at: Date
    public var undoable: Bool
    /// `granted`, `revoked`, or `team`, with the grant or team it changed, so a view can say
    /// it in words.
    public var kind: String? = nil
    public var grant: AccessGrantSummary? = nil
    public var team: AccessTeamSummary? = nil
    /// A later change undid this one.
    public var undone = false
}

/// Everything Settings ▸ Access shows.
public struct AccessOverview: Sendable, Hashable, Codable {
    /// Whether grants are enforced (decision 0066): false until the first grant or team, then
    /// true, also with none left in force, until someone turns enforcement off.
    public var enforced: Bool
    public var teams: [AccessTeamSummary]
    public var grants: [AccessGrantSummary]
    /// Newest first.
    public var refusals: [AccessRefusalSummary]
    /// Every person a grant or team can name: person bindings, team members, grant subjects.
    public var people: [String]
    public var resources: [AccessResource]
    public var lastChange: AccessChangeSummary?
    /// The latest changes, newest first (at most 12), for the audit trail.
    public var changes: [AccessChangeSummary] = []
    /// Since when enforcement has been in its current state (decision 0066), and the newest
    /// explicit enforcement change, when someone made one.
    public var enforcedSince: Date? = nil
    public var enforcement: AccessChangeSummary? = nil
}

extension Workspace {
    /// Teams, grants, recent refusals (at most `refusals`), and what can be granted.
    public func access(refusals limit: Int = 50) async throws -> AccessOverview {
        let book = try await sink.book(AccessBook.self)
        let state = try facadeState()
        let stewards = state.stewards.all
        var resources = [AccessResource(id: "*", kind: "everything", label: "Everything")]
        var people: [String] = []
        func person(_ id: String) {
            let id = Access.person(id)
            if id.hasPrefix("person:"), !people.contains(id) { people.append(id) }
        }
        var connections: [String: Set<String>] = [:]
        for steward in stewards {
            resources.append(
                AccessResource(
                    id: "steward:\(steward.id.rawValue)", kind: "steward",
                    label: steward.charter.name))
            for binding in steward.charter.bindings {
                switch binding.kind {
                case .person: person(binding.id)
                case .mcp: connections[binding.id, default: []].formUnion(binding.actions)
                }
            }
        }
        for (id, actions) in connections.sorted(by: { $0.key < $1.key }) {
            resources.append(AccessResource(id: "connection:\(id)", kind: "connection", label: id))
            for action in actions.sorted() {
                resources.append(
                    AccessResource(
                        id: "tool:\(id).\(action)", kind: "tool", label: "\(id).\(action)"))
            }
        }
        let teams = book.teams.values.sorted { $0.team < $1.team }
        for team in teams { team.members.forEach(person) }
        for grant in book.grants where grant.grant.subject.hasPrefix("person:") {
            person(grant.grant.subject)
        }
        let recent = book.changes.values.sorted { $0.seq > $1.seq }.prefix(12)
        func summary(_ change: AccessChangeRecord) -> AccessChangeSummary {
            AccessChangeSummary(
                seq: change.seq, text: Self.describe(change), by: change.by, at: change.at.date,
                undoable: change.undoneBy == nil && AccessAdmin.undo(change.seq, book: book) != nil,
                kind: Self.changeKind(change), grant: Self.grantSummary(change),
                team: change.team.map {
                    AccessTeamSummary(id: $0.team, name: $0.name, members: $0.members)
                },
                undone: change.undoneBy != nil)
        }
        let weekAgo = now().addingTimeInterval(-7 * 86_400)
        func grantSummary(_ record: AccessGrantRecord) -> AccessGrantSummary {
            let uses = book.uses[AccessBook.key(record.grant)] ?? []
            return AccessGrantSummary(
                subject: record.grant.subject, level: record.grant.level.rawValue,
                resource: record.grant.resource, by: record.by, at: record.at.date,
                seq: record.seq, uses: uses.filter { $0.at.date >= weekAgo }.count,
                lastUse: uses.last.map {
                    AccessUseSummary(
                        person: $0.used.person, action: $0.used.action, target: $0.used.target,
                        at: $0.at.date, steward: $0.steward?.rawValue, run: $0.run?.rawValue,
                        approval: $0.used.approval != nil)
                })
        }
        let ordered = book.changes.values.sorted { $0.seq < $1.seq }
        let switched = ordered.last { $0.enforcement != nil }
        let firstOn = ordered.first {
            $0.type == AccessEventType.granted || $0.type == AccessEventType.team
        }
        let since = switched?.enforcement == book.enforced ? switched : firstOn
        return AccessOverview(
            enforced: book.enforced,
            teams: teams.map { AccessTeamSummary(id: $0.team, name: $0.name, members: $0.members) },
            grants: book.grants.map(grantSummary),
            refusals: book.refusals.suffix(limit).reversed().map {
                AccessRefusalSummary(
                    seq: $0.seq, at: $0.at.date, steward: $0.steward?.rawValue,
                    run: $0.run?.rawValue, person: $0.refused.person,
                    level: $0.refused.level.rawValue, action: $0.refused.action,
                    reason: $0.refused.reason, resources: $0.refused.resources,
                    target: $0.refused.target,
                    asked: $0.run.flatMap { state.runs.records[$0]?.input })
            },
            people: people.sorted(), resources: resources,
            lastChange: recent.first.map(summary), changes: recent.map(summary),
            enforcedSince: (book.enforced ? since : switched)?.at.date,
            enforcement: switched.map(summary))
    }

    /// Grants `level` on `resource` to `subject` (`access.granted`, by `person`).
    @discardableResult
    public func grantAccess(
        _ level: String, on resource: String, to subject: String, reason: String? = nil,
        as person: String = "local"
    ) async throws -> AccessOverview {
        let grant = try Self.validGrant(level, resource, subject)
        try await change(
            AccessEventType.granted, AccessChange(grant: grant, reason: reason), as: person)
        return try await access()
    }

    /// Revokes a grant (`access.revoked`, by `person`).
    @discardableResult
    public func revokeAccess(
        _ level: String, on resource: String, from subject: String, reason: String? = nil,
        as person: String = "local"
    ) async throws -> AccessOverview {
        let grant = try Self.validGrant(level, resource, subject)
        guard try await sink.book(AccessBook.self).grants.contains(where: { $0.grant == grant })
        else { throw WorkspaceError.notFound("\(subject) \(level) \(resource)") }
        try await change(
            AccessEventType.revoked, AccessChange(grant: grant, reason: reason), as: person)
        return try await access()
    }

    /// Sets a team's name and whole member list (`access.team`); no members disbands it.
    @discardableResult
    public func setTeam(
        _ id: String, name: String? = nil, members: [String], as person: String = "local"
    ) async throws -> AccessOverview {
        let team = id.hasPrefix("team:") ? id : "team:" + id
        let slug = team.dropFirst(5)
        guard !slug.isEmpty, slug.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) })
        else { throw WorkspaceError.rejected("a team id is letters, digits, - and _") }
        var seen: [String] = []
        for member in members.map(Access.person) where !seen.contains(member) {
            guard member.hasPrefix("person:"), member.count > 7 else {
                throw WorkspaceError.rejected("\(member) is not a person")
            }
            seen.append(member)
        }
        let current = try await sink.book(AccessBook.self).teams[team]
        try await change(
            AccessEventType.team,
            AccessTeam(team: team, name: name ?? current?.name ?? String(slug), members: seen),
            as: person)
        return try await access()
    }

    /// Turns enforcement on or off (`access.enforcement`, decision 0066). Revoking the last
    /// grant leaves it on; this is the only way to turn it off. Undoable like any change.
    @discardableResult
    public func setAccessEnforcement(_ on: Bool, as person: String = "local") async throws
        -> AccessOverview
    {
        guard try await sink.book(AccessBook.self).enforced != on else {
            throw WorkspaceError.rejected("enforcement is already \(on ? "on" : "off")")
        }
        try await change(AccessEventType.enforcement, AccessEnforcement(on: on), as: person)
        return try await access()
    }

    /// Undoes access change `seq` by recording its inverse.
    @discardableResult
    public func undoAccess(_ seq: Int, as person: String = "local") async throws
        -> AccessOverview
    {
        let book = try await sink.book(AccessBook.self)
        if let refusal = AccessAdmin.refusal(person, book: book) {
            throw WorkspaceError.rejected(refusal)
        }
        guard let inverse = AccessAdmin.undo(seq, book: book) else {
            throw WorkspaceError.rejected("access change \(seq) cannot be undone")
        }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: inverse.type, steward: nil, run: nil, actor: .person(person),
                payload: inverse.payload))
        return try await access()
    }

    private func change(_ type: String, _ payload: some Encodable, as person: String)
        async throws
    {
        if let refusal = AccessAdmin.refusal(person, book: try await sink.book(AccessBook.self)) {
            throw WorkspaceError.rejected(refusal)
        }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: nil, run: nil, actor: .person(person),
                payload: try CanonicalJSON.decode(
                    JSONValue.self, from: try CanonicalJSON.encode(payload))))
    }

    static func validGrant(_ level: String, _ resource: String, _ subject: String) throws
        -> AccessGrant
    {
        guard let level = AccessLevel(rawValue: level) else {
            throw WorkspaceError.rejected("a level is view, approve, or use")
        }
        let subject = Access.person(subject)
        guard subject.split(separator: ":", maxSplits: 1).last.map({ !$0.isEmpty }) == true
        else { throw WorkspaceError.rejected("\(subject) is not a person or team") }
        let kinds = ["steward:", "connection:", "tool:"]
        guard
            resource == "*"
                || kinds.contains(where: { resource.hasPrefix($0) && resource.count > $0.count })
        else {
            throw WorkspaceError.rejected(
                "a resource is steward:<id>, connection:<binding>, tool:<binding>.<kind>, or *")
        }
        return AccessGrant(subject: subject, level: level, resource: resource)
    }

    static func changeKind(_ change: AccessChangeRecord) -> String {
        switch change.type {
        case AccessEventType.granted: "granted"
        case AccessEventType.revoked: "revoked"
        case AccessEventType.team: "team"
        case AccessEventType.enforcement: "enforcement"
        default: change.type
        }
    }

    static func grantSummary(_ change: AccessChangeRecord) -> AccessGrantSummary? {
        change.grant.map {
            AccessGrantSummary(
                subject: $0.subject, level: $0.level.rawValue, resource: $0.resource,
                by: change.by, at: change.at.date, seq: change.seq)
        }
    }

    static func describe(_ change: AccessChangeRecord) -> String {
        let undo = change.undoneBy != nil ? " (undone)" : ""
        if let grant = change.grant {
            let verb = change.type == AccessEventType.granted ? "Granted" : "Revoked"
            let to = change.type == AccessEventType.granted ? "to" : "from"
            return
                "\(verb) \(grant.level.rawValue) on \(grant.resource) \(to) \(grant.subject)\(undo)"
        }
        if let team = change.team {
            if team.members.isEmpty { return "Disbanded \(team.team)\(undo)" }
            return "Set \(team.team) to \(team.members.joined(separator: ", "))\(undo)"
        }
        if let on = change.enforcement {
            return "Turned enforcement \(on ? "on" : "off")\(undo)"
        }
        return change.type
    }
}
