import Arya
import Foundation

// Governance commands (ledger lane): policy and approvers, undo, retention, encryption, and
// signed export and import. `arya approve --as` and `arya run abort` live with the core
// commands; these read and change who may do what, and how long and how safely history is kept.

/// What the governance commands need from an arya home. The defaults keep backends without
/// governance (test doubles) compiling; they report "not available yet".
protocol GovernanceBackend: Sendable {
    func policy(steward: String) async throws(CLIError) -> PolicySummary
    func undoOptions(run: String) async throws(CLIError) -> [UndoOption]
    func undo(run: String, action: String, reason: String?) async throws(CLIError) -> UndoSummary
    func retention(steward: String?, days: Int?, clear: Bool) async throws(CLIError)
        -> RetentionSummary
    func applyRetention() async throws(CLIError) -> RetentionSummary
    func encryption(enable: Bool, reseal: Bool) async throws(CLIError) -> EncryptionSummary
    func exportSigned(steward: String, to directory: String, reveal: Bool)
        async throws(CLIError) -> AuditExportSummary
    func verifyExport(_ directory: String) async throws(CLIError) -> AuditExportSummary
    func importExport(_ directory: String) async throws(CLIError) -> AuditImportSummary
}

extension GovernanceBackend {
    func policy(steward: String) async throws(CLIError) -> PolicySummary {
        throw .unavailable("policySummary")
    }

    func undoOptions(run: String) async throws(CLIError) -> [UndoOption] {
        throw .unavailable("undoOptions")
    }

    func undo(run: String, action: String, reason: String?) async throws(CLIError) -> UndoSummary {
        throw .unavailable("undoAction")
    }

    func retention(steward: String?, days: Int?, clear: Bool) async throws(CLIError)
        -> RetentionSummary
    {
        throw .unavailable("retention")
    }

    func applyRetention() async throws(CLIError) -> RetentionSummary {
        throw .unavailable("applyRetention")
    }

    func encryption(enable: Bool, reseal: Bool) async throws(CLIError) -> EncryptionSummary {
        throw .unavailable("encryption")
    }

    func exportSigned(steward: String, to directory: String, reveal: Bool)
        async throws(CLIError) -> AuditExportSummary
    {
        throw .unavailable("exportAudit")
    }

    func verifyExport(_ directory: String) async throws(CLIError) -> AuditExportSummary {
        throw .unavailable("verifyAudit")
    }

    func importExport(_ directory: String) async throws(CLIError) -> AuditImportSummary {
        throw .unavailable("importAudit")
    }
}

extension CommandTable {
    /// Policy, undo, retention, encryption, and signed export and import (ledger lane).
    static let governance: [CommandSpec] = [
        CommandSpec(
            id: .stewardPolicy,
            summary: "Show a steward's tools and actions, who may approve them, and retention",
            positionals: [PositionalSpec(name: "steward", help: "steward id")]),
        CommandSpec(
            id: .undo,
            summary: "List a run's undoable actions, or undo one with its compensating action",
            positionals: [
                PositionalSpec(name: "run", help: "run id"),
                PositionalSpec(name: "action", isRequired: false, help: "action id to undo"),
            ],
            options: [
                OptionSpec(
                    name: "reason", kind: .value(placeholder: "text"), help: "why, for the ledger")
            ]),
        CommandSpec(
            id: .retention,
            summary: "Show or set how long history is kept; nothing is ever deleted",
            options: [
                OptionSpec(
                    name: "steward", kind: .value(placeholder: "id"),
                    help: "set this steward's own days instead of the home default"),
                OptionSpec(
                    name: "days", kind: .value(placeholder: "n"), help: "days of history to keep"),
                OptionSpec(name: "clear", kind: .flag, help: "remove the setting"),
            ]),
        CommandSpec(
            id: .retentionApply,
            summary: "Archive what retention covers now under a fresh checkpoint"),
        CommandSpec(
            id: .encryption, summary: "Show encryption at rest, turn it on, or seal earlier events",
            options: [
                OptionSpec(
                    name: "enable", kind: .flag,
                    help: "turn encryption on with a new key in the Keychain"),
                OptionSpec(
                    name: "reseal", kind: .flag,
                    help: "rewrite the ledger once with earlier clear payloads sealed"),
            ]),
        CommandSpec(
            id: .export,
            summary: "Write a steward's ledger slice signed with the home's checkpoint key",
            positionals: [PositionalSpec(name: "steward", help: "steward id")],
            options: [
                OptionSpec(
                    name: "out", kind: .value(placeholder: "dir"), isRequired: true,
                    help: "new folder for the export (never overwritten)"),
                OptionSpec(
                    name: "signed", kind: .flag, help: "accepted for clarity; exports are signed"
                ),
                OptionSpec(
                    name: "reveal", kind: .flag,
                    help: "include opened payloads of sealed events (needs the home key)"),
            ]),
        CommandSpec(
            id: .exportVerify,
            summary: "Check a signed export on its own; exits non-zero when it does not check",
            positionals: [PositionalSpec(name: "dir", help: "export folder")]),
        CommandSpec(
            id: .importExport,
            summary: "Recreate a steward from a checked export: latest charter and live memory",
            positionals: [PositionalSpec(name: "dir", help: "export folder")]),
    ]
}

extension CLI {
    /// Runs the governance commands.
    static func dispatchGovernance(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        switch invocation.command {
        case .stewardPolicy:
            try output.emit(
                try await backend.policy(steward: try invocation.positional("steward")),
                json: json, text: GovernanceText.policy)
        case .undo:
            let run = try invocation.positional("run")
            if let action = invocation.positionals["action"] {
                try output.emit(
                    try await backend.undo(
                        run: run, action: action, reason: invocation.values["reason"]),
                    json: json, text: GovernanceText.undone)
            } else {
                try output.emit(
                    try await backend.undoOptions(run: run), json: json,
                    text: GovernanceText.options)
            }
        case .retention:
            let clear = invocation.flags.contains("clear")
            var days: Int?
            if invocation.values["days"] != nil {
                days = try invocation.int("days", default: 0)
                if clear {
                    throw .usage("--days and --clear exclude each other", command: .retention)
                }
            }
            if invocation.values["steward"] != nil, days == nil, !clear {
                throw .usage("--steward needs --days or --clear", command: .retention)
            }
            try output.emit(
                try await backend.retention(
                    steward: invocation.values["steward"], days: days, clear: clear),
                json: json, text: GovernanceText.retention)
        case .retentionApply:
            try output.emit(
                try await backend.applyRetention(), json: json, text: GovernanceText.retention)
        case .encryption:
            let enable = invocation.flags.contains("enable")
            let reseal = invocation.flags.contains("reseal")
            try output.emit(
                try await backend.encryption(enable: enable, reseal: reseal), json: json,
                text: GovernanceText.encryption)
        case .export:
            try output.emit(
                try await backend.exportSigned(
                    steward: try invocation.positional("steward"),
                    to: invocation.values["out"] ?? "",
                    reveal: invocation.flags.contains("reveal")),
                json: json, text: GovernanceText.exported)
        case .exportVerify:
            let summary = try await backend.verifyExport(try invocation.positional("dir"))
            try output.emit(summary, json: json, text: GovernanceText.exported)
            if !summary.verified { throw .failed("the export does not check") }
        case .importExport:
            try output.emit(
                try await backend.importExport(try invocation.positional("dir")), json: json,
                text: GovernanceText.imported)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings of the governance commands.
enum GovernanceText {
    static func people(_ ids: [String]?) -> String {
        guard let ids else { return "anyone" }
        return ids.map { $0 == "local" ? "you" : $0 }.joined(separator: ", ")
    }

    static func policy(_ policy: PolicySummary) -> [String] {
        var lines = ["anything not listed: \(policy.fallback)"]
        if let autonomy = policy.autonomy { lines.insert("autonomy \(autonomy)", at: 0) }
        for binding in policy.bindings {
            lines.append("\(binding.id) (\(binding.kind))")
            for action in binding.actions {
                lines.append(
                    "  \(action.kind)  \(action.decision)  risk \(action.risk)  approvers "
                        + people(action.approvers))
            }
        }
        for rule in policy.approvers {
            let scope = rule.binding.map { "\(rule.action)@\($0)" } ?? rule.action
            lines.append("approvers \(scope): \(people(rule.people))")
        }
        return lines
    }

    static func options(_ options: [UndoOption]) -> [String] {
        guard !options.isEmpty else { return ["nothing to undo"] }
        return options.map { option in
            let target = option.target.map { " \($0)" } ?? ""
            let done = option.undoneBy.map { "  (undone by \($0))" } ?? ""
            return "\(option.action)  \(option.kind)\(target) -> \(option.with)\(done)"
        }
    }

    static func undone(_ summary: UndoSummary) -> [String] {
        let what = "\(summary.option.with) for \(summary.option.action)"
        if summary.executed { return ["undone: \(what) executed"] }
        if let approval = summary.approval {
            return ["undo waits for approval \(approval): \(what)"]
        }
        return ["undo \(summary.decision): \(summary.reason)"]
    }

    static func retention(_ summary: RetentionSummary) -> [String] {
        var lines = ["home default: " + (summary.defaultDays.map { "\($0) days" } ?? "forever")]
        lines += summary.stewards.map { "\($0.steward): \($0.days) days" }
        let events = summary.events.values.reduce(0, +)
        lines.append(
            summary.segments.isEmpty
                ? "nothing is old enough to archive"
                : "eligible: \(summary.segments.count) segments, \(events) events")
        if summary.archived > 0 { lines.append("archived: \(summary.archived) segments") }
        return lines
    }

    static func encryption(_ summary: EncryptionSummary) -> [String] {
        guard summary.enabled else { return ["encryption off"] }
        var lines = ["encryption on, key \(summary.key ?? "?")"]
        if !summary.keyAvailable { lines.append("the key is not in this Keychain") }
        lines.append("\(summary.clearEvents) earlier events in the clear")
        return lines
    }

    static func exported(_ summary: AuditExportSummary) -> [String] {
        var lines = [
            "\(summary.count) events to seq \(summary.head), signed \(summary.key): "
                + (summary.verified ? "verified" : "does not check")
        ]
        lines += summary.issues.map { "  " + $0 }
        return lines
    }

    static func imported(_ summary: AuditImportSummary) -> [String] {
        [
            "imported \(summary.steward) (\(summary.name)) with \(summary.notes) notes from an "
                + "export of \(summary.events) events signed \(summary.key)"
        ]
    }
}
