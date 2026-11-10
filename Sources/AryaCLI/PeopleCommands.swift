import Arya
import Foundation

/// What `arya message` and `arya report` need from an arya home. The defaults keep backends
/// without people (test doubles) compiling; they report "not available yet".
protocol PeopleBackend: Sendable {
    func message(steward: String, text: String, intent: String, by person: String)
        async throws(CLIError) -> MessageReceipt
    func reportDigest(steward: String) async throws(CLIError) -> ReportDigest
    func sendReport(steward: String) async throws(CLIError) -> ReportDigest
}

extension PeopleBackend {
    func message(steward: String, text: String, intent: String, by person: String)
        async throws(CLIError) -> MessageReceipt
    {
        throw .unavailable("message")
    }

    func reportDigest(steward: String) async throws(CLIError) -> ReportDigest {
        throw .unavailable("reportDigest")
    }

    func sendReport(steward: String) async throws(CLIError) -> ReportDigest {
        throw .unavailable("sendReport")
    }
}

extension CommandTable {
    /// Messages from people and periodic reports (connect lane).
    static let people: [CommandSpec] = [
        CommandSpec(
            id: .message,
            summary: "Message a steward as a person: ask, correct, or hand off work",
            positionals: [
                PositionalSpec(name: "steward", help: "steward id"),
                PositionalSpec(name: "text", help: "the message, quoted"),
            ],
            options: [
                OptionSpec(
                    name: "as", kind: .value(placeholder: "person"),
                    help: "the person binding it comes from (default: local)"),
                OptionSpec(
                    name: "intent", kind: .value(placeholder: "ask|correct|handoff"),
                    help: "what the person wants (default: ask)"),
            ]),
        CommandSpec(
            id: .reportShow, summary: "Show the periodic report a steward would send now",
            positionals: [PositionalSpec(name: "steward", help: "steward id")]),
        CommandSpec(
            id: .reportSend, summary: "Send a steward's periodic report now to its people",
            positionals: [PositionalSpec(name: "steward", help: "steward id")]),
    ]
}

extension CLI {
    /// Runs `message`, `report show`, or `report send`.
    static func dispatchPeople(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        let steward = try invocation.positional("steward")
        switch invocation.command {
        case .message:
            let receipt = try await backend.message(
                steward: steward, text: try invocation.positional("text"),
                intent: invocation.values["intent"] ?? "ask",
                by: invocation.values["as"] ?? "local")
            try output.emit(receipt, json: json, text: PeopleText.received)
        case .reportShow:
            try output.emit(
                try await backend.reportDigest(steward: steward), json: json,
                text: PeopleText.digest)
        case .reportSend:
            try output.emit(
                try await backend.sendReport(steward: steward), json: json, text: PeopleText.sent)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings of messages and reports.
enum PeopleText {
    static func received(_ receipt: MessageReceipt) -> [String] {
        var lines = ["recorded \(receipt.event)"]
        if let note = receipt.note { lines.append("kept as memory \(note)") }
        if let run = receipt.run {
            lines.append("run \(run.id) \(run.status.rawValue)")
        }
        return lines
    }

    static func digest(_ digest: ReportDigest) -> [String] {
        let to = digest.to.map { $0.name ?? $0.person }.joined(separator: ", ")
        let header =
            digest.configured
            ? "\(digest.cadence) report to \(to.isEmpty ? "no one" : to)"
            : "no report in the charter; preview to \(to.isEmpty ? "no one" : to)"
        return [header] + digest.lines.map { "  " + $0 }
    }

    static func sent(_ digest: ReportDigest) -> [String] {
        let to = digest.to.map { $0.name ?? $0.person }.joined(separator: ", ")
        return ["sent the \(digest.cadence) report to \(to)"] + digest.lines.map { "  " + $0 }
    }
}
