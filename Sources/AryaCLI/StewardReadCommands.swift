import Arya
import Foundation

/// What `arya steward onboard|gate|trajectories|metrics` need from an arya home: a steward's
/// onboarding, its go-live gate, its graded runs, and its metrics against target. The
/// defaults keep test doubles compiling; they report "not available yet".
protocol StewardReadBackend: Sendable {
    func onboarding(steward: String) async throws(CLIError) -> OnboardingState
    func goLiveGate(steward: String, agreed: Int?) async throws(CLIError) -> GoLiveSummary
    func trajectories(steward: String) async throws(CLIError) -> TrajectorySummary
    func metricStatuses(steward: String, windows: Int?) async throws(CLIError) -> [MetricStatus]
}

extension StewardReadBackend {
    func onboarding(steward: String) async throws(CLIError) -> OnboardingState {
        throw .unavailable("onboardingState")
    }
    func goLiveGate(steward: String, agreed: Int?) async throws(CLIError) -> GoLiveSummary {
        throw .unavailable("goLiveGate")
    }
    func trajectories(steward: String) async throws(CLIError) -> TrajectorySummary {
        throw .unavailable("trajectories")
    }
    func metricStatuses(steward: String, windows: Int?) async throws(CLIError) -> [MetricStatus] {
        throw .unavailable("metricStatuses")
    }
}

extension CommandTable {
    /// A steward's onboarding, go-live gate, graded runs, and metrics.
    static let stewardReads: [CommandSpec] = [
        CommandSpec(
            id: .stewardOnboarding, summary: "Show how far a steward has come learning its job",
            positionals: [PositionalSpec(name: "steward", help: "steward id")]),
        CommandSpec(
            id: .stewardGate, summary: "Check whether a steward is ready to go live",
            positionals: [PositionalSpec(name: "steward", help: "steward id")],
            options: [
                OptionSpec(
                    name: "agreed", kind: .value(placeholder: "n"),
                    help: "agreed reviews needed (default 10, or every case of a smaller queue)")
            ]),
        CommandSpec(
            id: .stewardTrajectories,
            summary: "Grade a steward's runs on the follow-up checks that came after them",
            positionals: [PositionalSpec(name: "steward", help: "steward id")]),
        CommandSpec(
            id: .stewardMetrics, summary: "Show a steward's metric and guardrails against target",
            positionals: [PositionalSpec(name: "steward", help: "steward id")],
            options: [
                OptionSpec(
                    name: "windows", kind: .value(placeholder: "n"),
                    help: "trend windows to show (default: the evaluation window)")
            ]),
    ]
}

extension CLI {
    /// Runs `steward onboard`, `steward gate`, `steward trajectories`, or `steward metrics`.
    static func dispatchStewardReads(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        let steward = try invocation.positional("steward")
        switch invocation.command {
        case .stewardOnboarding:
            try output.emit(
                try await backend.onboarding(steward: steward), json: json,
                text: StewardReadText.onboarding)
        case .stewardGate:
            let agreed = try invocation.values["agreed"].map { value throws(CLIError) in
                guard let number = Int(value), number > 0 else {
                    throw .usage("--agreed needs a positive whole number")
                }
                return number
            }
            try output.emit(
                try await backend.goLiveGate(steward: steward, agreed: agreed), json: json,
                text: StewardReadText.gate)
        case .stewardTrajectories:
            try output.emit(
                try await backend.trajectories(steward: steward), json: json,
                text: StewardReadText.trajectories)
        case .stewardMetrics:
            let windows = try invocation.values["windows"].map { value throws(CLIError) in
                guard let number = Int(value), number > 0 else {
                    throw .usage("--windows needs a positive whole number")
                }
                return number
            }
            try output.emit(
                try await backend.metricStatuses(steward: steward, windows: windows), json: json,
                text: StewardReadText.metrics)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings; each leads with the facade's verbatim sentence.
enum StewardReadText {
    static func onboarding(_ state: OnboardingState) -> [String] {
        [state.summary] + state.steps.map { "  [\($0.done ? "x" : " ")] \($0.title): \($0.detail)" }
    }

    static func gate(_ gate: GoLiveSummary) -> [String] {
        [gate.summary] + gate.conditions.map { "  [\($0.met ? "x" : " ")] \($0.key): \($0.detail)" }
    }

    static func trajectories(_ view: TrajectorySummary) -> [String] {
        [view.sentence, "  \(view.good) good, \(view.bad) bad, \(view.pending) pending"]
    }

    static func metrics(_ statuses: [MetricStatus]) -> [String] {
        statuses.map { "\($0.role == "primary" ? "metric   " : "guardrail") \($0.line)" }
    }
}
