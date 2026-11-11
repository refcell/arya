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

    /// "person:sam" reads "sam"; "team:support" reads "support (team)".
    static func subject(_ id: String, teams: [AccessTeamSummary] = []) -> String {
        if id.hasPrefix("team:") {
            let name = teams.first { $0.id == id }?.name ?? String(id.dropFirst(5))
            return "\(name) (team)"
        }
        return id.hasPrefix("person:") ? String(id.dropFirst(7)) : id
    }

    /// "local · 3h": who made a change and when.
    static func byline(_ by: String, _ at: Date, now: Date, lead: String = "") -> String {
        "\(lead)\(subject(by)) · \(AryaTime.label(at, now: now))"
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
