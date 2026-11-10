/// Every command the CLI dispatches. Exhaustive switches keep the table and the handlers in step.
enum CommandID: String, Sendable, Equatable, CaseIterable {
    case initHome = "init"
    case stewardCreate = "steward create"
    case stewardList = "steward list"
    case stewardShow = "steward show"
    case stewardPause = "steward pause"
    case stewardResume = "steward resume"
    case fleet
    case run
    case runShow = "run show"
    case runAbort = "run abort"
    case approvals
    case approve
    case deny
    case ledgerTail = "ledger tail"
    case ledgerVerify = "ledger verify"
    case casebookImport = "casebook import"
    case casebookList = "casebook list"
    case rehearse
    case correct
    case runCorrect = "run correct"
    case ready
    case propose
    case proposals
    case readiness
    case metrics
    case memory
    case retract
    case routines
    case replay
    case bindingProxy = "binding-proxy"
    case serve
    case serveInstall = "serve install"
    case serveUninstall = "serve uninstall"
    case historyImport = "history import"
    case review
    case message
    case reportShow = "report show"
    case reportSend = "report send"
    case stewardPolicy = "steward policy", undo, retention, retentionApply = "retention apply"
    case encryption, export, exportVerify = "export verify", importExport = "import"
}

/// A command's path, help text, and accepted arguments.
struct CommandSpec: Sendable, Equatable {
    let id: CommandID
    let summary: String
    var positionals: [PositionalSpec] = []
    var options: [OptionSpec] = []

    /// The words that select this command: `["steward", "create"]`.
    var path: [String] { id.rawValue.split(separator: " ").map(String.init) }

    /// The option with this long name or one-letter alias.
    func option(named name: String) -> OptionSpec? {
        options.first { $0.name == name || ($0.short.map { String($0) } == name) }
    }

    /// The one-line usage: `arya steward show <steward>`.
    var usage: String {
        var parts = ["arya"] + path
        for positional in positionals {
            parts.append(positional.isRequired ? "<\(positional.name)>" : "[<\(positional.name)>]")
        }
        for option in options where option.isRequired {
            parts.append(Self.render(option))
        }
        for option in options where !option.isRequired {
            parts.append("[\(Self.render(option))]")
        }
        return parts.joined(separator: " ")
    }

    private static func render(_ option: OptionSpec) -> String {
        switch option.kind {
        case .flag: "--\(option.name)"
        case .value(let placeholder): "--\(option.name) <\(placeholder)>"
        }
    }
}

/// The command table, in help order.
enum CommandTable {
    static let all: [CommandSpec] =
        [
            CommandSpec(id: .initHome, summary: "Create an arya home (ledger, blobs, cache)"),
            CommandSpec(
                id: .stewardCreate, summary: "Define a steward from a charter file",
                options: [
                    OptionSpec(
                        name: "charter", kind: .value(placeholder: "file"), isRequired: true,
                        help: "charter JSON (docs/ARCHITECTURE.md, Charters and cases)")
                ]),
            CommandSpec(id: .stewardList, summary: "List stewards"),
            CommandSpec(
                id: .stewardShow, summary: "Show a steward's charter and state",
                positionals: [
                    PositionalSpec(name: "steward", help: "steward id, such as st_triage")
                ]),
            CommandSpec(
                id: .stewardPause, summary: "Pause a steward: no triggers fire until it resumes",
                positionals: [PositionalSpec(name: "steward", help: "steward id")]),
            CommandSpec(
                id: .stewardResume, summary: "Resume a paused steward",
                positionals: [PositionalSpec(name: "steward", help: "steward id")]),
            CommandSpec(
                id: .fleet,
                summary: "Every steward's metric against its target, what needs you, next wake"),
            CommandSpec(
                id: .run, summary: "Start a manual run now and wait for it to finish",
                positionals: [PositionalSpec(name: "steward", help: "steward id")],
                options: [
                    OptionSpec(
                        name: "input", kind: .value(placeholder: "text"),
                        help: "input text for the run (default: none)")
                ]),
            CommandSpec(
                id: .runShow, summary: "Show a run's decisions and what happened to each action",
                positionals: [PositionalSpec(name: "run", help: "run id")]),
            CommandSpec(
                id: .runAbort, summary: "Stop a running run; nothing it proposes executes",
                positionals: [PositionalSpec(name: "run", help: "run id")],
                options: [
                    OptionSpec(
                        name: "reason", kind: .value(placeholder: "text"),
                        help: "why, recorded with the request")
                ]),
            CommandSpec(
                id: .approvals, summary: "List actions held for approval",
                options: [
                    OptionSpec(
                        name: "steward", kind: .value(placeholder: "id"),
                        help: "only this steward's approvals"),
                    OptionSpec(name: "all", kind: .flag, help: "include decided approvals"),
                ]),
            CommandSpec(
                id: .approve, summary: "Approve a held action; it executes right away",
                positionals: [PositionalSpec(name: "approval", help: "approval id")],
                options: [
                    noteOption,
                    OptionSpec(
                        name: "as", kind: .value(placeholder: "person"),
                        help: "who approves: local (default) or a person binding id"),
                ]),
            CommandSpec(
                id: .deny, summary: "Deny a held action; it is never executed",
                positionals: [PositionalSpec(name: "approval", help: "approval id")],
                options: [noteOption]),
            CommandSpec(
                id: .ledgerTail, summary: "Show the latest ledger events",
                options: [
                    OptionSpec(
                        name: "count", short: "n", kind: .value(placeholder: "n"),
                        help: "how many events (default 20)"),
                    OptionSpec(
                        name: "steward", kind: .value(placeholder: "id"),
                        help: "only this steward's events"),
                ]),
            CommandSpec(id: .ledgerVerify, summary: "Check the ledger's hash chain and sequence"),
        ] + improvement + history + people + governance

    /// M2 commands: the improvement loop.
    private static let improvement: [CommandSpec] = [
        CommandSpec(
            id: .casebookImport, summary: "Import a casebook (JSON Lines) for a steward",
            positionals: [
                stewardArgument,
                PositionalSpec(name: "file", help: "casebook file, one case per line"),
            ],
            options: [
                OptionSpec(
                    name: "name", kind: .value(placeholder: "name"),
                    help: "casebook name (default: the file name without extension)")
            ]),
        CommandSpec(
            id: .casebookList, summary: "List casebooks and their versions",
            options: [stewardFilter]),
        CommandSpec(
            id: .rehearse, summary: "Rehearse a steward on a casebook; no action is executed",
            positionals: [stewardArgument],
            options: [
                OptionSpec(
                    name: "casebook", kind: .value(placeholder: "name"),
                    help: "casebook to use (default: the steward's latest import)")
            ]),
        CommandSpec(
            id: .correct, summary: "Correct a rehearsed case; the note becomes a memory",
            positionals: [stewardArgument, PositionalSpec(name: "case", help: "case id")],
            options: [
                OptionSpec(
                    name: "choice", kind: .value(placeholder: "choice"),
                    help: "the decision the case expects instead"),
                noteOption,
            ]),
        CommandSpec(
            id: .runCorrect, summary: "Correct what a run decided; it becomes a case and a memory",
            positionals: [PositionalSpec(name: "run", help: "run id")],
            options: [
                OptionSpec(
                    name: "choice", kind: .value(placeholder: "choice"), isRequired: true,
                    help: "the decision the run should have made"),
                noteOption,
            ]),
        CommandSpec(
            id: .ready, summary: "Mark a steward ready for live triggers",
            positionals: [stewardArgument]),
        CommandSpec(
            id: .propose, summary: "Propose a new charter version; it is rehearsed and gated",
            positionals: [stewardArgument],
            options: [
                OptionSpec(
                    name: "charter", kind: .value(placeholder: "file"), isRequired: true,
                    help: "the proposed charter JSON")
            ]),
        CommandSpec(
            id: .proposals, summary: "List proposals and their gate results",
            options: [stewardFilter]),
        CommandSpec(
            id: .readiness,
            summary: "Backtest a proposal: its casebook gate and recent runs replayed under it",
            positionals: [PositionalSpec(name: "proposal", help: "proposal id")]),
        CommandSpec(
            id: .metrics, summary: "Show a steward's outcome metric series",
            positionals: [stewardArgument],
            options: [
                OptionSpec(
                    name: "metric", kind: .value(placeholder: "name"),
                    help: "only this metric")
            ]),
        CommandSpec(
            id: .memory, summary: "List a steward's memory notes",
            positionals: [stewardArgument],
            options: [OptionSpec(name: "all", kind: .flag, help: "include retracted notes")]),
        CommandSpec(
            id: .retract, summary: "Retract a memory note; later runs no longer recall it",
            positionals: [PositionalSpec(name: "memory", help: "memory note id")],
            options: [
                OptionSpec(
                    name: "reason", kind: .value(placeholder: "text"),
                    help: "why it is wrong (default: none)")
            ]),
        CommandSpec(
            id: .routines, summary: "List a steward's routines and live versions",
            positionals: [stewardArgument]),
        CommandSpec(
            id: .replay, summary: "Replay a run on its recorded inputs and report divergence",
            positionals: [PositionalSpec(name: "run", help: "run id")]),
        CommandSpec(
            id: .bindingProxy, summary: "Serve one binding's read tools over stdio (used by runs)",
            options: [
                OptionSpec(
                    name: "steward", kind: .value(placeholder: "id"), isRequired: true,
                    help: "the run's steward"),
                OptionSpec(
                    name: "run", kind: .value(placeholder: "id"), isRequired: true,
                    help: "the run the calls belong to"),
                OptionSpec(
                    name: "binding", kind: .value(placeholder: "id"), isRequired: true,
                    help: "the charter binding to serve"),
                OptionSpec(
                    name: "recorded", kind: .value(placeholder: "file"),
                    help: "answer from recorded tool results (rehearsal and replay)"),
            ]),
        CommandSpec(
            id: .serve, summary: "Fire scheduled and message triggers until stopped",
            options: [
                everyOption,
                OptionSpec(
                    name: "demo-pace", kind: .flag,
                    help: "also start a demo run every 20 to 40 seconds"),
            ]),
        CommandSpec(
            id: .serveInstall, summary: "Run `arya serve` for this home at login (LaunchAgent)",
            options: [everyOption]),
        CommandSpec(id: .serveUninstall, summary: "Remove the `arya serve` login item"),
    ]

    private static let everyOption = OptionSpec(
        name: "every", kind: .value(placeholder: "seconds"),
        help: "seconds between scheduler ticks (default 60)")

    private static let stewardArgument = PositionalSpec(name: "steward", help: "steward id")

    private static let stewardFilter = OptionSpec(
        name: "steward", kind: .value(placeholder: "id"), help: "only this steward's")

    private static let noteOption = OptionSpec(
        name: "note", kind: .value(placeholder: "text"), help: "a note recorded with the decision")

    /// The spec for a command id.
    static func spec(_ id: CommandID) -> CommandSpec {
        all.first { $0.id == id } ?? CommandSpec(id: id, summary: "")
    }
}
