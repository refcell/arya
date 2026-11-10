import Arya
import Foundation

/// What `arya routine library`, `arya routine adopt`, and `arya run crew` need (connect lane,
/// M3.6 #7 and #10). Defaults keep test doubles compiling; they report "not available yet".
protocol RoutineLibraryBackend: Sendable {
    func routineLibrary() async throws(CLIError) -> [SharedRoutineSummary]
    func adoptRoutine(
        name: String, version: String, from source: String, into target: String, by person: String
    ) async throws(CLIError) -> RoutineAdoption
    func crew(run: String) async throws(CLIError) -> CrewFanoutSummary
}

extension RoutineLibraryBackend {
    func routineLibrary() async throws(CLIError) -> [SharedRoutineSummary] {
        throw .unavailable("routineLibrary")
    }

    func adoptRoutine(
        name: String, version: String, from source: String, into target: String, by person: String
    ) async throws(CLIError) -> RoutineAdoption {
        throw .unavailable("adoptRoutine")
    }

    func crew(run: String) async throws(CLIError) -> CrewFanoutSummary {
        throw .unavailable("crew")
    }
}

extension CommandTable {
    /// The Routines library and the crew fan-out (connect lane).
    static let library: [CommandSpec] = [
        CommandSpec(
            id: .routineLibrary,
            summary: "List every routine across stewards: who has it, live versions, pass rate"),
        CommandSpec(
            id: .routineAdopt,
            summary: "Use one steward's routine version in another, gated on its casebook",
            positionals: [
                PositionalSpec(name: "name", help: "routine name"),
                PositionalSpec(name: "version", help: "routine version"),
            ],
            options: [
                OptionSpec(
                    name: "from", kind: .value(placeholder: "steward"),
                    help: "the steward that has it"),
                OptionSpec(
                    name: "into", kind: .value(placeholder: "steward"),
                    help: "the steward to propose it to"),
                OptionSpec(
                    name: "as", kind: .value(placeholder: "person"),
                    help: "who asks (default: local)"),
            ]),
        CommandSpec(
            id: .runCrew, summary: "Show a crew run's delegates: status, outcome, duration",
            positionals: [PositionalSpec(name: "run", help: "run id")]),
    ]
}

extension CLI {
    /// Runs `routine library`, `routine adopt`, or `run crew`.
    static func dispatchLibrary(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        switch invocation.command {
        case .routineLibrary:
            try output.emit(
                try await backend.routineLibrary(), json: json, text: LibraryText.routines)
        case .routineAdopt:
            guard let source = invocation.values["from"], let target = invocation.values["into"]
            else { throw .usage("routine adopt needs --from and --into") }
            let gated = try await backend.adoptRoutine(
                name: try invocation.positional("name"),
                version: try invocation.positional("version"), from: source, into: target,
                by: invocation.values["as"] ?? "local")
            try output.emit(gated, json: json, text: LibraryText.adopted)
        case .runCrew:
            try output.emit(
                try await backend.crew(run: try invocation.positional("run")), json: json,
                text: LibraryText.crew)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings of the library and the fan-out.
enum LibraryText {
    static func routines(_ rows: [SharedRoutineSummary]) -> [String] {
        guard !rows.isEmpty else { return ["no routines"] }
        return rows.map { row in
            let stewards = row.uses.map { use in
                "\(use.steward) \(use.liveVersion.map { String($0.prefix(12)) } ?? "not live")"
            }
            let settled = row.passed + row.failed
            let rate = settled == 0 ? "no settled runs" : "\(row.passed * 100 / settled)% pass"
            return "\(row.name)  \(stewards.joined(separator: ", "))  \(row.runs) runs, \(rate)"
        }
    }

    static func adopted(_ adoption: RoutineAdoption) -> [String] {
        let short = String(adoption.version.prefix(12))
        guard let gate = adoption.gate else {
            return [
                "proposed \(adoption.name) \(short) to \(adoption.steward); no casebook to gate on"
            ]
        }
        return [
            gate.promoted
                ? "live in \(adoption.steward): the gate passed"
                : "proposed to \(adoption.steward): the gate held it (\(gate.proposal))"
        ]
    }

    static func crew(_ fanout: CrewFanoutSummary) -> [String] {
        ["\(fanout.host.id) \(fanout.host.status.rawValue)"]
            + fanout.children.map { child in
                let tail = child.refused ?? child.summary ?? ""
                return "  \(child.delegation) \(child.status)  \(child.title)"
                    + (tail.isEmpty ? "" : " · \(tail)")
            }
    }
}
