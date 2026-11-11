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
    /// False while the home has no grants or teams: nothing is enforced yet.
    public var enforced: Bool
    public var teams: [AccessTeamSummary]
    public var grants: [AccessGrantSummary]
    /// Newest first.
    public var refusals: [AccessRefusalSummary]
    /// Every person a grant or team can name: person bindings, team members, grant subjects.
    public var people: [String]
    public var resources: [AccessResource]
    public var lastChange: AccessChangeSummary?
}

extension Workspace {
    /// Teams, grants, recent refusals (at most `refusals`), and what can be granted.
    public func access(refusals limit: Int = 50) async throws -> AccessOverview {
        let book = try await sink.book(AccessBook.self)
        let stewards = try facadeState().stewards.all
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
        let last = book.changes.values.max { $0.seq < $1.seq }
        return AccessOverview(
            enforced: !book.isEmpty,
            teams: teams.map { AccessTeamSummary(id: $0.team, name: $0.name, members: $0.members) },
            grants: book.grants.map {
                AccessGrantSummary(
                    subject: $0.grant.subject, level: $0.grant.level.rawValue,
                    resource: $0.grant.resource, by: $0.by, at: $0.at.date, seq: $0.seq)
            },
            refusals: book.refusals.suffix(limit).reversed().map {
                AccessRefusalSummary(
                    seq: $0.seq, at: $0.at.date, steward: $0.steward?.rawValue,
                    run: $0.run?.rawValue, person: $0.refused.person,
                    level: $0.refused.level.rawValue, action: $0.refused.action,
                    reason: $0.refused.reason, resources: $0.refused.resources)
            },
            people: people.sorted(), resources: resources,
            lastChange: last.map {
                AccessChangeSummary(
                    seq: $0.seq, text: Self.describe($0), by: $0.by, at: $0.at.date,
                    undoable: $0.undoneBy == nil && AccessAdmin.undo($0.seq, book: book) != nil,
                    kind: Self.changeKind($0), grant: Self.grantSummary($0),
                    team: $0.team.map {
                        AccessTeamSummary(id: $0.team, name: $0.name, members: $0.members)
                    },
                    undone: $0.undoneBy != nil)
            })
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
        return change.type
    }
}
