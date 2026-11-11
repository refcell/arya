import Arya
import AryaDesign
import Foundation
import Observation

// Settings ▸ Access (runtime lane, decisions 0064 and 0065): teams, grants on stewards,
// connections, and tools, and recent refusals, read and changed through the facade. The
// Settings window hosts `AccessSettingsView` with one line.

/// The access calls the app makes. `Workspace` provides all of them.
protocol AccessSettingsSource: Sendable {
    func access(refusals: Int) async throws -> AccessOverview
    func grantAccess(
        _ level: String, on resource: String, to subject: String, reason: String?,
        as person: String
    ) async throws -> AccessOverview
    func revokeAccess(
        _ level: String, on resource: String, from subject: String, reason: String?,
        as person: String
    ) async throws -> AccessOverview
    func setTeam(_ id: String, name: String?, members: [String], as person: String) async throws
        -> AccessOverview
    func undoAccess(_ seq: Int, as person: String) async throws -> AccessOverview
}

extension Workspace: AccessSettingsSource {}

extension AppModel {
    /// The access calls, when this home's source offers them.
    var access: (any AccessSettingsSource)? { source as? any AccessSettingsSource }
}

/// What a grant form has chosen so far.
struct GrantDraft: Equatable {
    var subject: String?
    var level = "use"
    var resource: String?

    var ready: Bool { subject != nil && resource != nil }
}

/// The access overview, kept between redraws, and the writes that change it.
@MainActor @Observable
final class AccessModel {
    static let shared = AccessModel()

    private(set) var overview: AccessOverview?
    /// The last failed write or read, phrased by the facade.
    var problem: String?

    init(overview: AccessOverview? = nil) {
        self.overview = overview
    }

    /// Shows `overview` as is (snapshots and previews).
    func replace(_ overview: AccessOverview) {
        self.overview = overview
    }

    func load(from source: any AccessSettingsSource) async {
        await attempt { try await source.access(refusals: 50) }
    }

    func grant(_ draft: GrantDraft, from source: any AccessSettingsSource) async -> Bool {
        guard let subject = draft.subject, let resource = draft.resource else { return false }
        return await attempt {
            try await source.grantAccess(
                draft.level, on: resource, to: subject, reason: nil, as: "local")
        }
    }

    func revoke(_ grant: AccessGrantSummary, from source: any AccessSettingsSource) async {
        await attempt {
            try await source.revokeAccess(
                grant.level, on: grant.resource, from: grant.subject, reason: nil, as: "local")
        }
    }

    func setTeam(
        _ id: String, name: String?, members: [String], from source: any AccessSettingsSource
    ) async -> Bool {
        await attempt { try await source.setTeam(id, name: name, members: members, as: "local") }
    }

    func undo(from source: any AccessSettingsSource) async {
        guard let change = overview?.lastChange, change.undoable else { return }
        await attempt { try await source.undoAccess(change.seq, as: "local") }
    }

    @discardableResult
    private func attempt(_ body: () async throws -> AccessOverview) async -> Bool {
        do {
            overview = try await body()
            problem = nil
            return true
        } catch {
            problem = AccessText.problem(error)
            return false
        }
    }
}

/// Words the Access views show.
enum AccessText {
    /// A facade error in plain words.
    static func problem(_ error: any Error) -> String {
        if let error = error as? WorkspaceError {
            switch error {
            case .rejected(let reason): return "Could not change access: \(reason)."
            case .notFound(let what): return "Could not change access: \(what) is gone."
            default: break
            }
        }
        return "Could not change access. Try again."
    }

    /// Who a grant names, as people read it: "person:sam" is "Sam", "team:support" the team's
    /// name, "local" (the owner at this Mac) "You".
    static func who(_ id: String, teams: [AccessTeamSummary] = []) -> String {
        if id == "local" { return "You" }
        if id.hasPrefix("team:") {
            return teams.first { $0.id == id }?.name ?? words(String(id.dropFirst(5)))
        }
        return HumanText.name(id)
    }

    /// `who` in a list, with teams marked: "Support (team)".
    static func subject(_ id: String, teams: [AccessTeamSummary] = []) -> String {
        id.hasPrefix("team:") ? "\(who(id, teams: teams)) (team)" : who(id, teams: teams)
    }

    /// "You · 3h": who made a change and when.
    static func byline(_ by: String, _ at: Date, now: Date, lead: String = "") -> String {
        "\(lead)\(who(by)) · \(AryaTime.label(at, now: now))"
    }

    /// What a grant covers, by name: "everything", "Triage" for a steward, "Billing" for a
    /// connection, "refund on Billing" for a tool.
    static func resource(_ id: String, in resources: [AccessResource]) -> String {
        if id == "*" { return "everything" }
        if id.hasPrefix("steward:") {
            return resources.first { $0.id == id }?.label ?? HumanText.name(id)
        }
        if id.hasPrefix("connection:") { return words(String(id.dropFirst(11))) }
        if id.hasPrefix("tool:") {
            let parts = id.dropFirst(5).split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return HumanText.name(id) }
            return "\(HumanText.verb(parts[1])) on \(words(parts[0]))"
        }
        return HumanText.name(id)
    }

    /// `resource` as a heading: "Everything", "Refund on Billing".
    static func title(_ id: String, in resources: [AccessResource]) -> String {
        let name = resource(id, in: resources)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The kind of a resource, shown quietly after its name, or nil for everything.
    static func kind(_ id: String) -> String? {
        ["steward", "connection", "tool"].first { id.hasPrefix($0 + ":") }
    }

    /// "can use", "can approve", "can see".
    static func can(_ level: String) -> String {
        switch level {
        case "use": "can use"
        case "approve": "can approve"
        default: "can see"
        }
    }

    /// A grant as a sentence: "Jules can approve everything".
    static func grant(
        _ grant: AccessGrantSummary, teams: [AccessTeamSummary], resources: [AccessResource]
    ) -> String {
        "\(who(grant.subject, teams: teams)) \(can(grant.level)) "
            + resource(grant.resource, in: resources)
    }

    /// The last change in words: "Jules can approve everything", "Sam can no longer use
    /// Billing", "Support is Alex and Sam", "Disbanded Support".
    static func change(_ change: AccessChangeSummary, in overview: AccessOverview) -> String {
        let undone = change.undone ? " (undone)" : ""
        if let grant = change.grant {
            let line = Self.grant(grant, teams: overview.teams, resources: overview.resources)
            if change.kind == "revoked" {
                let name = who(grant.subject, teams: overview.teams)
                return line.replacingOccurrences(of: "\(name) can ", with: "\(name) can no longer ")
                    + undone
            }
            return line + undone
        }
        if let team = change.team {
            if team.members.isEmpty { return "Disbanded \(team.name)\(undone)" }
            return "\(team.name) is \(list(team.members.map { who($0) }))\(undone)"
        }
        return HumanText.sentence(change.text) + undone
    }

    /// A refusal in words: "Sam can't refund on Billing", "Sam can't approve reply for Triage".
    static func refusal(_ refusal: AccessRefusalSummary, in overview: AccessOverview) -> String {
        let name = who(refusal.person, teams: overview.teams)
        let verb = HumanText.verb(refusal.action)
        if refusal.level == "approve" {
            guard let steward = refusal.steward else { return "\(name) can't approve \(verb)" }
            return "\(name) can't approve \(verb) for \(self.steward(steward, in: overview))"
        }
        guard let connection = refusal.resources.first(where: { $0.hasPrefix("connection:") })
        else {
            return refusal.resources.isEmpty
                ? HumanText.sentence(refusal.reason) : "\(name) can't \(verb)"
        }
        return "\(name) can't \(verb) on \(resource(connection, in: overview.resources))"
    }

    /// A steward's name from its id.
    static func steward(_ id: String, in overview: AccessOverview) -> String {
        resource("steward:\(id)", in: overview.resources)
    }

    /// Who may change access: you (the owner), then anyone who can approve everything.
    static func admins(_ overview: AccessOverview) -> [String] {
        let holders = overview.grants.filter { $0.resource == "*" && $0.level == "approve" }
            .map { subject($0.subject, teams: overview.teams) }
        return ["You"] + holders.sorted()
    }

    /// "alerts" reads "Alerts", "support-desk" "Support Desk".
    static func words(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "Alex", "Alex and Sam", "Alex, Jules, and Sam".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }

    /// The status line under the title.
    static func status(_ overview: AccessOverview) -> String {
        guard overview.enforced else {
            return "Not enforced: with no grants or teams, a steward may act for anyone."
        }
        let grants = overview.grants.count
        let teams = overview.teams.count
        return "Enforced · \(grants) grant\(grants == 1 ? "" : "s") · \(teams) team"
            + (teams == 1 ? "" : "s")
    }

    /// What each level allows, for the grant form.
    static func level(_ level: String) -> String {
        switch level {
        case "use": "Act through it on their behalf"
        case "approve": "Decide its approvals"
        default: "See it"
        }
    }
}
