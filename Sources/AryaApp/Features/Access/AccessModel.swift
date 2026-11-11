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
        let effect = HumanText.effect(kind: refusal.action)
        guard let connection = refusal.resources.first(where: { $0.hasPrefix("connection:") })
        else {
            return refusal.resources.isEmpty
                ? HumanText.sentence(refusal.reason) : "\(name) can't \(effect)"
        }
        return "\(name) can't \(effect) in \(resource(connection, in: overview.resources))"
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

    /// "alerts" reads "Alerts", "support-desk" "Support Desk", and a short id like "crm" is an
    /// acronym, "CRM".
    static func words(_ id: String) -> String {
        if id.count <= 3, id.allSatisfy(\.isLetter) { return id.uppercased() }
        return id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// What `person` may do, through their own grants and their teams': "use Churn watch and
    /// Ledger · approve everything", or "No grants" when nothing covers them.
    static func effective(_ person: String, in overview: AccessOverview) -> String {
        let teams = Set(overview.teams.filter { $0.members.contains(person) }.map(\.id))
        return covers(
            overview.grants.filter { $0.subject == person || teams.contains($0.subject) },
            in: overview)
    }

    /// What a team's own grants let its members touch: "can use Invoice chasing and Ledger".
    static func touches(_ team: AccessTeamSummary, in overview: AccessOverview) -> String {
        let line = covers(overview.grants.filter { $0.subject == team.id }, in: overview)
        return line == "No grants" ? "No grants of its own" : "can " + line
    }

    /// Grants by level in words: "use Churn watch and Ledger · approve everything".
    static func covers(_ mine: [AccessGrantSummary], in overview: AccessOverview) -> String {
        let parts = ["use", "approve", "view"].compactMap { level -> String? in
            let names = mine.filter { $0.level == level }
                .map { resource($0.resource, in: overview.resources) }
            guard !names.isEmpty else { return nil }
            let verb = level == "view" ? "see" : level
            return "\(verb) \(list(Array(Set(names)).sorted()))"
        }
        return parts.isEmpty ? "No grants" : parts.joined(separator: " · ")
    }

    /// How a grant was used: "Used 3× this week · last by Sam: label MSG-140 · 2h", or "Not used
    /// yet".
    static func use(_ grant: AccessGrantSummary, now: Date) -> String {
        guard let last = grant.lastUse else { return "Not used yet" }
        let count = grant.uses == 0 ? "Not used this week" : "Used \(grant.uses)× this week"
        let step = HumanText.step(kind: last.action, target: last.target ?? "")
        let lowered = step.prefix(1).lowercased() + step.dropFirst()
        let what = last.approval ? "approved \(lowered)" : lowered
        return "\(count) · last by \(who(last.person)): \(what) · "
            + AryaTime.label(last.at, now: now)
    }

    /// What the refused run was asked, quoted, without the "person:kai hands this to you:"
    /// lead: "“Post tonight's on-call summary”".
    static func asked(_ refusal: AccessRefusalSummary) -> String? {
        guard var text = refusal.asked?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return refusal.target.map { "on \(HumanText.name($0))" } }
        if text.hasPrefix("person:"), let colon = text.range(of: ": ") {
            text = String(text[colon.upperBound...])
        }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let quoted = "“\(line.trimmingCharacters(in: .whitespaces))”"
        guard let target = refusal.target.map(HumanText.name), !line.contains(target) else {
            return quoted
        }
        return "\(quoted) · \(target)"
    }

    /// Enforcement and its last change: "On since Nov 2, from the first grant", "Turned off by
    /// Jules · 3h".
    static func enforcement(_ overview: AccessOverview, now: Date) -> String {
        if let change = overview.enforcement {
            let turned = overview.enforced ? "Turned on" : "Turned off"
            return "\(turned) by \(who(change.by)) · \(AryaTime.label(change.at, now: now))"
        }
        guard overview.enforced else { return "Off: no grant or team yet" }
        guard let since = overview.enforcedSince else { return "On" }
        return "On since \(AryaTime.label(since, now: now)), from the first grant or team"
    }

    /// The grants used this week, most used first (at most 5).
    static func mostUsed(_ overview: AccessOverview) -> [AccessGrantSummary] {
        Array(
            overview.grants.filter { $0.uses > 0 }
                .sorted { ($0.uses, -$0.seq) > ($1.uses, -$1.seq) }.prefix(5))
    }

    /// Refusals in the last 7 days by person, most first: who, what was refused ("post,
    /// publish"), and how often.
    static func refusedBy(_ overview: AccessOverview, now: Date)
        -> [(person: String, what: String, count: Int)]
    {
        let week = overview.refusals.filter { now.timeIntervalSince($0.at) < 7 * 86_400 }
        let people = Dictionary(grouping: week, by: \.person)
        return people.map { person, rows in
            var kinds: [String] = []
            for row in rows where !kinds.contains(row.action) { kinds.append(row.action) }
            return (person, kinds.map(HumanText.verb).joined(separator: ", "), rows.count)
        }
        .sorted { ($0.count, $1.person) > ($1.count, $0.person) }
    }

    /// The teams `person` is in, by name.
    static func teams(of person: String, in overview: AccessOverview) -> [String] {
        overview.teams.filter { $0.members.contains(person) }.map(\.name)
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
