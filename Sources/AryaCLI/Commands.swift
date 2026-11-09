/// Every command the CLI dispatches. Exhaustive switches keep the table and the handlers in step.
enum CommandID: String, Sendable, Equatable, CaseIterable {
    case initHome = "init"
    case stewardCreate = "steward create"
    case stewardList = "steward list"
    case stewardShow = "steward show"
    case run
    case approvals
    case approve
    case deny
    case ledgerTail = "ledger tail"
    case ledgerVerify = "ledger verify"
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
    static let all: [CommandSpec] = [
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
            positionals: [PositionalSpec(name: "steward", help: "steward id, such as st_triage")]),
        CommandSpec(
            id: .run, summary: "Start a manual run now and wait for it to finish",
            positionals: [PositionalSpec(name: "steward", help: "steward id")],
            options: [
                OptionSpec(
                    name: "input", kind: .value(placeholder: "text"),
                    help: "input text for the run (default: none)")
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
            options: [noteOption]),
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
    ]

    private static let noteOption = OptionSpec(
        name: "note", kind: .value(placeholder: "text"), help: "a note recorded with the decision")

    /// The spec for a command id.
    static func spec(_ id: CommandID) -> CommandSpec {
        all.first { $0.id == id } ?? CommandSpec(id: id, summary: "")
    }
}
