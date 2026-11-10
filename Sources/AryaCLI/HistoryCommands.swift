import Arya
import Foundation

/// What `arya history import` and `arya review` need from an arya home. The defaults keep
/// backends without history (test doubles) compiling; they report "not available yet".
protocol HistoryBackend: Sendable {
    func importHistory(
        steward: String, file: String?, binding: String?, tool: String?, limit: Int
    ) async throws(CLIError) -> HistoryImportSummary
    func reviewQueue(steward: String) async throws(CLIError) -> ReviewQueueSummary?
    func reviewCase(steward: String, case: String, verdict: String) async throws(CLIError)
        -> ReviewQueueSummary?
    func learnedChecks(steward: String) async throws(CLIError) -> LearnedChecksSummary?
    func buildCasebook(steward: String, limit: Int) async throws(CLIError) -> CasebookBuildSummary
}

extension HistoryBackend {
    func importHistory(
        steward: String, file: String?, binding: String?, tool: String?, limit: Int
    ) async throws(CLIError) -> HistoryImportSummary {
        throw .unavailable("importHistory")
    }

    func reviewQueue(steward: String) async throws(CLIError) -> ReviewQueueSummary? {
        throw .unavailable("reviewQueue")
    }

    func reviewCase(steward: String, case: String, verdict: String) async throws(CLIError)
        -> ReviewQueueSummary?
    {
        throw .unavailable("reviewCase")
    }

    func learnedChecks(steward: String) async throws(CLIError) -> LearnedChecksSummary? {
        throw .unavailable("learnedChecks")
    }

    func buildCasebook(steward: String, limit: Int) async throws(CLIError) -> CasebookBuildSummary {
        throw .unavailable("buildCasebook")
    }
}

extension CommandTable {
    /// History import and the review queue.
    static let history: [CommandSpec] = [
        CommandSpec(
            id: .historyImport,
            summary: "Import past items and what people did as cases (newest first, deduped)",
            positionals: [PositionalSpec(name: "steward", help: "steward id")],
            options: [
                OptionSpec(
                    name: "file", kind: .value(placeholder: "path"),
                    help: "export file in the binding history shape ({\"history\": [...]})"),
                OptionSpec(
                    name: "binding", kind: .value(placeholder: "id"),
                    help: "binding to page through; with --file, the binding the records are from"
                ),
                OptionSpec(
                    name: "from", kind: .value(placeholder: "binding"),
                    help: "the same as --binding: a connector such as `arya-binding folder <dir>`"),
                OptionSpec(
                    name: "tool", kind: .value(placeholder: "name"),
                    help: "the binding's history tool (default: history)"),
                OptionSpec(
                    name: "limit", kind: .value(placeholder: "n"),
                    help: "most cases to add (default: 200)"),
            ]),
        CommandSpec(
            id: .review,
            summary: "Review cases: what the steward would do vs what the person did",
            positionals: [PositionalSpec(name: "steward", help: "steward id")],
            options: [
                OptionSpec(
                    name: "case", kind: .value(placeholder: "id"), help: "the case to review"),
                OptionSpec(
                    name: "verdict", kind: .value(placeholder: "agree|skip"),
                    help: "agree or skip (correct a case with `arya correct`)"),
            ]),
        CommandSpec(
            id: .checks,
            summary: "Checks people taught the steward by correcting and agreeing, and its score",
            positionals: [PositionalSpec(name: "steward", help: "steward id")]),
        CommandSpec(
            id: .casebookBuild,
            summary: "Grow the casebook from live runs: corrected, denied, then accepted ones",
            positionals: [PositionalSpec(name: "steward", help: "steward id")],
            options: [
                OptionSpec(
                    name: "limit", kind: .value(placeholder: "n"),
                    help: "most cases to add (default: 60)")
            ]),
    ]
}

extension CLI {
    /// Runs `history import` or `review`.
    static func dispatchHistory(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        let values = invocation.values
        let steward = try invocation.positional("steward")
        switch invocation.command {
        case .historyImport:
            if values["from"] != nil, values["binding"] != nil {
                throw .usage("give --from or --binding, not both", command: .historyImport)
            }
            let binding = values["from"] ?? values["binding"]
            guard values["file"] != nil || binding != nil else {
                throw .usage("give --file or --from", command: .historyImport)
            }
            var limit = 200
            if let raw = values["limit"] {
                guard let parsed = Int(raw), parsed > 0 else {
                    throw .usage("--limit must be a positive number", command: .historyImport)
                }
                limit = parsed
            }
            let summary = try await backend.importHistory(
                steward: steward, file: values["file"], binding: binding, tool: values["tool"],
                limit: limit)
            try output.emit(summary, json: json, text: HistoryText.imported)
        case .review:
            let queue: ReviewQueueSummary?
            if let caseID = values["case"] {
                guard let verdict = values["verdict"] else {
                    throw .usage("give --verdict agree or skip with --case", command: .review)
                }
                queue = try await backend.reviewCase(
                    steward: steward, case: caseID, verdict: verdict)
            } else {
                queue = try await backend.reviewQueue(steward: steward)
            }
            guard let queue else { throw .notFound("casebook for \(steward)") }
            try output.emit(queue, json: json, text: HistoryText.queue)
        case .casebookBuild:
            var limit = 60
            if let raw = values["limit"] {
                guard let parsed = Int(raw), parsed > 0 else {
                    throw .usage("--limit must be a positive number", command: .casebookBuild)
                }
                limit = parsed
            }
            let summary = try await backend.buildCasebook(steward: steward, limit: limit)
            try output.emit(summary, json: json, text: { [$0.summary] })
        case .checks:
            guard let checks = try await backend.learnedChecks(steward: steward) else {
                throw .notFound("checks for \(steward) (review or correct a case first)")
            }
            try output.emit(checks, json: json, text: HistoryText.checks)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings of history imports and the review queue.
enum HistoryText {
    static func imported(_ summary: HistoryImportSummary) -> [String] {
        var lines = [summary.summary]
        lines += summary.invalid.map { "  invalid: \($0)" }
        return lines
    }

    /// The sentence, then one line per check: `FAIL  c2  Feature requests are features.`
    static func checks(_ checks: LearnedChecksSummary) -> [String] {
        [checks.sentence]
            + checks.results.map { line in
                let mark = line.passed.map { $0 ? "pass" : "FAIL" } ?? "-   "
                return "  \(mark)  \(line.result)"
            }
    }

    static func queue(_ queue: ReviewQueueSummary) -> [String] {
        var lines = ["\(queue.casebook) for \(queue.steward): \(queue.progressText)"]
        guard let next = queue.next else {
            return lines + ["every case is reviewed"]
        }
        lines += [
            "next: \(next.caseID)",
            "  input:        \(next.input)",
            "  would have:   \(next.wouldHave)",
            "  person did:   \(next.personDid)",
        ]
        if !next.difference.isEmpty { lines.append("  difference:   \(next.difference)") }
        if !next.source.isEmpty { lines.append("  source:       \(next.source)") }
        return lines
    }
}
