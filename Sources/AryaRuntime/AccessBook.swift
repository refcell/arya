import AryaAdapters
import AryaCore
import AryaLedger

// The grant store (decision 0065, on 0064): grants and teams are ledger events, home-wide (no
// steward), so every change is attributable, auditable, and undoable by its inverse event.

/// Access event types.
public enum AccessEventType {
    /// `access.granted` (`AccessChange`).
    public static let granted = "access.granted"
    /// `access.revoked` (`AccessChange`).
    public static let revoked = "access.revoked"
    /// `access.team` (`AccessTeam`): a team's name and its whole member list.
    public static let team = "access.team"
    /// `access.refused` (`AccessRefused`): a use or approve refused for want of a grant.
    public static let refused = "access.refused"
    /// `access.enforcement` (`AccessEnforcement`): the operator turned enforcement on or off.
    public static let enforcement = "access.enforcement"
}

/// `access.enforcement`: enforcement on or off, set by the operator (decision 0066). Without
/// one, the first grant or team turns enforcement on, and it stays on (fail closed).
public struct AccessEnforcement: Sendable, Hashable, Codable {
    public var on: Bool
    public var undoes: Int?

    public init(on: Bool, undoes: Int? = nil) {
        self.on = on
        self.undoes = undoes
    }
}

/// `access.granted` and `access.revoked`.
public struct AccessChange: Sendable, Hashable, Codable {
    public var grant: AccessGrant
    public var reason: String?
    /// The seq of the change this one undoes, when it is an undo.
    public var undoes: Int?

    public init(grant: AccessGrant, reason: String? = nil, undoes: Int? = nil) {
        self.grant = grant
        self.reason = reason
        self.undoes = undoes
    }
}

/// `access.team`: the team's whole state after the change (empty members disbands it).
public struct AccessTeam: Sendable, Hashable, Codable {
    /// `team:<id>`.
    public var team: String
    public var name: String
    /// `person:<id>` each.
    public var members: [String]
    public var undoes: Int?

    public init(team: String, name: String, members: [String], undoes: Int? = nil) {
        self.team = team
        self.name = name
        self.members = members
        self.undoes = undoes
    }
}

/// `access.refused` (steward and run of what was refused; actor: the system for a use, the
/// person for an approve).
public struct AccessRefused: Sendable, Hashable, Codable {
    /// `person:<id>`.
    public var person: String
    public var level: AccessLevel
    /// The action kind refused or held for approval.
    public var action: String
    /// The resources a grant could have covered, broadest first.
    public var resources: [String]
    /// The plain reason, as shown to people.
    public var reason: String
    public var approval: ApprovalID?

    public init(
        person: String, level: AccessLevel, action: String, resources: [String], reason: String,
        approval: ApprovalID? = nil
    ) {
        self.person = person
        self.level = level
        self.action = action
        self.resources = resources
        self.reason = reason
        self.approval = approval
    }
}

/// One grant in force and who gave it.
public struct AccessGrantRecord: Sendable, Hashable, Codable {
    public var grant: AccessGrant
    public var by: String
    public var seq: Int
    public var at: Timestamp
}

/// One team and who last changed it.
public struct AccessTeamRecord: Sendable, Hashable, Codable {
    public var team: String
    public var name: String
    public var members: [String]
    public var seq: Int
}

/// One refusal, for the Refused list.
public struct AccessRefusalRecord: Sendable, Hashable, Codable {
    public var seq: Int
    public var at: Timestamp
    public var steward: StewardID?
    public var run: RunID?
    public var refused: AccessRefused
}

/// One change, for undo.
public struct AccessChangeRecord: Sendable, Hashable, Codable {
    public var seq: Int
    public var type: String
    public var by: String
    public var at: Timestamp
    public var grant: AccessGrant?
    public var team: AccessTeam?
    /// The team as it was before this change, for undoing a team change.
    public var priorTeam: AccessTeam?
    /// Set once a later change undid this one.
    public var undoneBy: Int?
    /// For `access.enforcement`: what it set, and whether enforcement was on before it.
    public var enforcement: Bool? = nil
    public var priorEnforced: Bool? = nil
}

/// Folds the access events.
public struct AccessBook: RuntimeBook {
    public static let cacheName = "runtime.access.v2"

    public private(set) var grants: [AccessGrantRecord] = []
    public private(set) var teams: [String: AccessTeamRecord] = [:]
    public private(set) var changes: [Int: AccessChangeRecord] = [:]
    /// Refusals, newest last, at most `refusalLimit`.
    public private(set) var refusals: [AccessRefusalRecord] = []
    /// Whether grants are enforced (decision 0066): on from the first grant or team, and it
    /// stays on when the last one is revoked (with none in force, everything that needs a
    /// grant is refused); only `access.enforcement` turns it off, and a later grant or team,
    /// or the operator, turns it on again.
    public private(set) var enforced = false

    /// Refusals kept for the Refused list.
    public static let refusalLimit = 200

    enum CodingKeys: String, CodingKey { case grants, teams, changes, refusals, enforced }

    public init() {}

    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    /// True when the home has neither grants nor teams in force. Whether grants are enforced
    /// is `enforced`, which stays on after the last one is revoked.
    public var isEmpty: Bool { grants.isEmpty && teams.isEmpty }

    /// The grants and teams in force.
    public var inForce: AccessGrants {
        AccessGrants(
            grants: grants.map(\.grant),
            teams: teams.mapValues(\.members))
    }

    public mutating func apply(_ event: RuntimeEvent) throws {
        switch event.type {
        case AccessEventType.granted, AccessEventType.revoked:
            let change = try Payload.decode(AccessChange.self, event.payload)
            grants.removeAll { $0.grant == change.grant }
            if event.type == AccessEventType.granted {
                enforced = true
                grants.append(
                    AccessGrantRecord(
                        grant: change.grant, by: event.draft.actor.id, seq: event.seq,
                        at: event.at))
            }
            record(event, grant: change.grant, undoes: change.undoes)
        case AccessEventType.team:
            let team = try Payload.decode(AccessTeam.self, event.payload)
            let prior = teams[team.team].map {
                AccessTeam(team: $0.team, name: $0.name, members: $0.members)
            }
            if team.members.isEmpty {
                teams[team.team] = nil
            } else {
                enforced = true
                teams[team.team] = AccessTeamRecord(
                    team: team.team, name: team.name, members: team.members, seq: event.seq)
            }
            record(
                event, team: team,
                prior: prior
                    ?? AccessTeam(
                        team: team.team, name: team.name, members: []), undoes: team.undoes)
        case AccessEventType.enforcement:
            let change = try Payload.decode(AccessEnforcement.self, event.payload)
            let prior = enforced
            enforced = change.on
            record(event, undoes: change.undoes)
            changes[event.seq]?.enforcement = change.on
            changes[event.seq]?.priorEnforced = prior
        case AccessEventType.refused:
            refusals.append(
                AccessRefusalRecord(
                    seq: event.seq, at: event.at, steward: event.draft.steward,
                    run: event.draft.run,
                    refused: try Payload.decode(AccessRefused.self, event.payload)))
            if refusals.count > Self.refusalLimit {
                refusals.removeFirst(refusals.count - Self.refusalLimit)
            }
        default: return
        }
    }

    private mutating func record(
        _ event: RuntimeEvent, grant: AccessGrant? = nil, team: AccessTeam? = nil,
        prior: AccessTeam? = nil, undoes: Int?
    ) {
        changes[event.seq] = AccessChangeRecord(
            seq: event.seq, type: event.type, by: event.draft.actor.id, at: event.at,
            grant: grant, team: team, priorTeam: prior)
        if let undoes { changes[undoes]?.undoneBy = event.seq }
    }
}

/// Changing grants and teams.
public enum AccessAdmin {
    /// Why `person` may not change grants, or nil when they may: the local owner, or anyone
    /// with an `approve` grant on `*` (an access admin).
    public static func refusal(_ person: String, book: AccessBook) -> String? {
        guard !Access.isOwner(person) else { return nil }
        if book.inForce.grant(.approve, person: person, on: []) != nil { return nil }
        return "\(Access.person(person)) may not change access; only the owner or someone"
            + " who approves everything (*) may"
    }

    /// The event that undoes change `seq`, or nil when it cannot be undone (unknown, already
    /// undone, or itself an undo).
    public static func undo(_ seq: Int, book: AccessBook) -> (type: String, payload: JSONValue)? {
        guard let change = book.changes[seq], change.undoneBy == nil else { return nil }
        do {
            switch change.type {
            case AccessEventType.granted, AccessEventType.revoked:
                guard let grant = change.grant else { return nil }
                let inverse =
                    change.type == AccessEventType.granted
                    ? AccessEventType.revoked : AccessEventType.granted
                return (
                    inverse,
                    try Payload.encode(AccessChange(grant: grant, reason: "undo", undoes: seq))
                )
            case AccessEventType.team:
                guard var prior = change.priorTeam else { return nil }
                prior.undoes = seq
                return (AccessEventType.team, try Payload.encode(prior))
            case AccessEventType.enforcement:
                guard let prior = change.priorEnforced else { return nil }
                return (
                    AccessEventType.enforcement,
                    try Payload.encode(AccessEnforcement(on: prior, undoes: seq))
                )
            default: return nil
            }
        } catch {
            return nil
        }
    }
}
