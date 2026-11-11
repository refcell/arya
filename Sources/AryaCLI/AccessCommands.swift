import Arya
import Foundation

// `arya access` (workspace lane, M3.6 #13): teams, view/approve/use grants on stewards,
// connections, and tools, recent refusals, and undo, over the workspace's access facade.

/// What the access commands need from an arya home. The defaults keep test doubles compiling.
protocol AccessBackend: Sendable {
    func access(refusals: Int) async throws(CLIError) -> AccessOverview
    func grantAccess(
        _ level: String, on resource: String, to subject: String, reason: String?,
        as person: String?
    ) async throws(CLIError) -> AccessOverview
    func revokeAccess(
        _ level: String, on resource: String, from subject: String, reason: String?,
        as person: String?
    ) async throws(CLIError) -> AccessOverview
    func setTeam(_ id: String, name: String?, members: [String], as person: String?)
        async throws(CLIError) -> AccessOverview
    func undoAccess(_ seq: Int, as person: String?) async throws(CLIError) -> AccessOverview
    func setAccessEnforcement(_ on: Bool, as person: String?) async throws(CLIError)
        -> AccessOverview
}

extension AccessBackend {
    func access(refusals: Int) async throws(CLIError) -> AccessOverview {
        throw .unavailable("access")
    }

    func grantAccess(
        _ level: String, on resource: String, to subject: String, reason: String?,
        as person: String?
    ) async throws(CLIError) -> AccessOverview {
        throw .unavailable("grantAccess")
    }

    func revokeAccess(
        _ level: String, on resource: String, from subject: String, reason: String?,
        as person: String?
    ) async throws(CLIError) -> AccessOverview {
        throw .unavailable("revokeAccess")
    }

    func setTeam(_ id: String, name: String?, members: [String], as person: String?)
        async throws(CLIError) -> AccessOverview
    {
        throw .unavailable("setTeam")
    }

    func undoAccess(_ seq: Int, as person: String?) async throws(CLIError) -> AccessOverview {
        throw .unavailable("undoAccess")
    }

    func setAccessEnforcement(_ on: Bool, as person: String?) async throws(CLIError)
        -> AccessOverview
    {
        throw .unavailable("setAccessEnforcement")
    }
}

extension CommandTable {
    private static let asPerson = OptionSpec(
        name: "as", kind: .value(placeholder: "person"),
        help: "who makes the change, for the ledger (default: you)")
    private static let reason = OptionSpec(
        name: "reason", kind: .value(placeholder: "text"), help: "why, kept with the change")
    private static let grantArgs = [
        PositionalSpec(name: "level", help: "view, approve, or use"),
        PositionalSpec(
            name: "resource",
            help: "steward:<id>, connection:<binding>, tool:<binding>.<action kind>, or *"),
        PositionalSpec(name: "subject", help: "person:<id> or team:<id>"),
    ]

    /// Teams and grants (workspace lane).
    static let access: [CommandSpec] = [
        CommandSpec(
            id: .accessList, summary: "Show teams, grants, recent refusals, and the last change",
            options: [
                OptionSpec(
                    name: "refusals", kind: .value(placeholder: "n"),
                    help: "refusals to show (default 20)")
            ]),
        CommandSpec(
            id: .accessGrant,
            summary: "Let a person or team view, approve, or use a steward, connection, or tool",
            positionals: grantArgs, options: [reason, asPerson]),
        CommandSpec(
            id: .accessRevoke, summary: "Remove a grant", positionals: grantArgs,
            options: [reason, asPerson]),
        CommandSpec(
            id: .accessTeam, summary: "Set a team's members; no members disbands it",
            positionals: [
                PositionalSpec(name: "team", help: "team id (team:<id> or <id>)"),
                PositionalSpec(
                    name: "members", isRequired: false,
                    help: "comma-separated people (person:alex,person:sam); omit to disband"),
            ],
            options: [
                OptionSpec(name: "name", kind: .value(placeholder: "text"), help: "display name"),
                asPerson,
            ]),
        CommandSpec(
            id: .accessUndo, summary: "Undo an access change by its seq",
            positionals: [PositionalSpec(name: "seq", help: "the change's ledger seq")],
            options: [asPerson]),
        CommandSpec(
            id: .accessEnforce,
            summary: "Turn grant enforcement on or off (it stays on after the last revoke)",
            positionals: [PositionalSpec(name: "state", help: "on or off")],
            options: [asPerson]),
    ]
}

extension CLI {
    static func dispatchAccess(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let person = invocation.values["as"]
        let reason = invocation.values["reason"]
        let overview: AccessOverview
        switch invocation.command {
        case .accessList:
            let limit = invocation.values["refusals"].map { Int($0) } ?? 20
            guard let limit, limit >= 0 else {
                throw .usage("--refusals must be a number", command: .accessList)
            }
            overview = try await backend.access(refusals: limit)
        case .accessGrant:
            overview = try await backend.grantAccess(
                try invocation.positional("level"), on: try invocation.positional("resource"),
                to: try invocation.positional("subject"), reason: reason, as: person)
        case .accessRevoke:
            overview = try await backend.revokeAccess(
                try invocation.positional("level"), on: try invocation.positional("resource"),
                from: try invocation.positional("subject"), reason: reason, as: person)
        case .accessTeam:
            let members = (invocation.positionals["members"] ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            overview = try await backend.setTeam(
                try invocation.positional("team"), name: invocation.values["name"],
                members: members, as: person)
        case .accessUndo:
            guard let seq = Int(try invocation.positional("seq")) else {
                throw .usage("seq must be a number", command: .accessUndo)
            }
            overview = try await backend.undoAccess(seq, as: person)
        case .accessEnforce:
            let state = try invocation.positional("state")
            guard state == "on" || state == "off" else {
                throw .usage("state is on or off", command: .accessEnforce)
            }
            overview = try await backend.setAccessEnforcement(state == "on", as: person)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
        try output.emit(overview, json: invocation.global.isJSON, text: AccessText.overview)
    }
}

enum AccessText {
    static func overview(_ overview: AccessOverview) -> [String] {
        var lines = [
            overview.enforced
                ? "\(overview.grants.count) grants, \(overview.teams.count) teams; enforced."
                    + (overview.grants.isEmpty && overview.teams.isEmpty
                        ? " With none in force, anything that needs a grant is refused." : "")
                : overview.grants.isEmpty && overview.teams.isEmpty
                    ? "No grants or teams: nothing is enforced."
                    : "\(overview.grants.count) grants, \(overview.teams.count) teams; "
                        + "enforcement is off."
        ]
        if !overview.teams.isEmpty {
            lines.append("teams:")
            for team in overview.teams {
                let members = team.members.isEmpty ? "nobody" : team.members.joined(separator: ", ")
                lines.append("  \(team.id)  \(members)")
            }
        }
        if !overview.grants.isEmpty {
            lines.append("grants:")
            for grant in overview.grants.sorted(by: { $0.seq < $1.seq }) {
                lines.append(
                    "  \(grant.subject) may \(grant.level) on \(grant.resource)  (seq \(grant.seq))"
                )
            }
        }
        if !overview.refusals.isEmpty {
            lines.append("refusals (newest first):")
            for refusal in overview.refusals { lines.append("  \(refusal.seq)  \(refusal.reason)") }
        }
        if let last = overview.lastChange {
            let undo = last.undoable ? "  (undo: arya access undo \(last.seq))" : ""
            lines.append("last change: \(last.text)\(undo)")
        }
        return lines
    }
}
