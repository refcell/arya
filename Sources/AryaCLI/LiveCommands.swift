import Arya
import Foundation

/// What `arya run facts` and `arya steward live` need from an arya home: the one source of
/// run numbers and live state every screen reads. The defaults keep test doubles compiling;
/// they report "not available yet".
protocol LiveBackend: Sendable {
    func runFacts(run: String) async throws(CLIError) -> RunFacts
    func stewardLive(steward: String) async throws(CLIError) -> StewardLive
}

extension LiveBackend {
    func runFacts(run: String) async throws(CLIError) -> RunFacts {
        throw .unavailable("runFacts")
    }
    func stewardLive(steward: String) async throws(CLIError) -> StewardLive {
        throw .unavailable("stewardLive")
    }
}

extension CommandTable {
    /// A run's numbers and a steward's live state.
    static let live: [CommandSpec] = [
        CommandSpec(
            id: .runFacts, summary: "Show a run's numbers: steps, decisions, actions, time",
            positionals: [PositionalSpec(name: "run", help: "run id")]),
        CommandSpec(
            id: .stewardLive, summary: "Show what a steward is doing now and when it wakes next",
            positionals: [PositionalSpec(name: "steward", help: "steward id")]),
    ]
}

extension CLI {
    /// Runs `run facts` or `steward live`.
    static func dispatchLive(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        switch invocation.command {
        case .runFacts:
            let facts = try await backend.runFacts(run: try invocation.positional("run"))
            try output.emit(facts, json: json, text: LiveText.facts)
        case .stewardLive:
            let live = try await backend.stewardLive(steward: try invocation.positional("steward"))
            try output.emit(live, json: json, text: LiveText.live)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings of run facts and live state.
enum LiveText {
    static func facts(_ facts: RunFacts) -> [String] {
        let steps =
            facts.estimatedSteps.map { "\(facts.stepIndex) of ~\($0)" } ?? "\(facts.stepIndex)"
        return [
            "\(facts.run) \(facts.steward) \(facts.status), \(Int(facts.elapsedSeconds)) s",
            "  \(facts.title)",
            "  steps \(steps) · decisions \(facts.decisions) · tool calls \(facts.toolCalls)",
            "  actions \(facts.actionsProposed) proposed, \(facts.actionsApplied) applied, "
                + "\(facts.actionsDrafted) drafted, \(facts.actionsFailed) failed, "
                + "\(facts.actionsWaiting) waiting" + (facts.dryRun ? " (dry run)" : ""),
        ]
    }

    static func live(_ live: StewardLive) -> [String] {
        var lines: [String] = []
        if let run = live.running {
            let more = live.alsoRunning > 0 ? " (+\(live.alsoRunning) more)" : ""
            lines.append("\(live.steward) running \(run.run), step \(run.stepIndex)\(more)")
        } else {
            lines.append("\(live.steward) idle")
        }
        let next = live.nextWake.map { ", next wake \($0.absolute)" } ?? ""
        lines.append("  schedule \(live.schedule)\(next)\(live.serving ? ", served" : "")")
        return lines
    }
}
