import Foundation

extension CLI {
    /// Runs one improvement-loop command (M2).
    static func dispatchImprovement(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        let values = invocation.values
        switch invocation.command {
        case .casebookImport:
            let row = try await backend.importCasebook(
                steward: try invocation.positional("steward"),
                path: try invocation.positional("file"), name: values["name"])
            try output.emit(row, json: json, text: ImprovementText.imported)
        case .casebookList:
            let rows = try await backend.listCasebooks(steward: values["steward"])
            try output.emit(rows, json: json, text: ImprovementText.casebooks)
        case .rehearse:
            let report = try await backend.rehearse(
                steward: try invocation.positional("steward"), casebook: values["casebook"])
            try output.emit(report, json: json, text: ImprovementText.rehearsal)
        case .correct:
            guard values["choice"] != nil || values["note"] != nil else {
                throw .usage("give --choice, --note, or both", command: .correct)
            }
            let report = try await backend.correct(
                steward: try invocation.positional("steward"),
                case: try invocation.positional("case"), choice: values["choice"],
                note: values["note"])
            try output.emit(report, json: json, text: ImprovementText.correction)
        case .ready:
            let detail = try await backend.markReady(steward: try invocation.positional("steward"))
            try output.emit(detail, json: json, text: TextRender.steward)
        default:
            try await dispatchInspection(invocation, backend: backend, output: output)
        }
    }

    /// Proposals, metrics, memory, routines, replay, and the binding proxy.
    private static func dispatchInspection(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        let values = invocation.values
        switch invocation.command {
        case .propose:
            let row = try await backend.propose(
                steward: try invocation.positional("steward"),
                charterPath: values["charter"] ?? "")
            try output.emit(row, json: json, text: { ImprovementText.proposals([$0]) })
        case .proposals:
            let rows = try await backend.listProposals(steward: values["steward"])
            try output.emit(rows, json: json, text: ImprovementText.proposals)
        case .metrics:
            let series = try await backend.metrics(
                steward: try invocation.positional("steward"), metric: values["metric"])
            try output.emit(series, json: json, text: ImprovementText.metrics)
        case .memory:
            let scope: MemoryScope = invocation.flags.contains("all") ? .all : .live
            let rows = try await backend.memory(
                steward: try invocation.positional("steward"), scope: scope)
            try output.emit(rows, json: json, text: ImprovementText.memory)
        case .routines:
            let rows = try await backend.routines(steward: try invocation.positional("steward"))
            try output.emit(rows, json: json, text: ImprovementText.routines)
        case .replay:
            let report = try await backend.replay(run: try invocation.positional("run"))
            try output.emit(report, json: json, text: ImprovementText.replay)
            if !report.divergences.isEmpty {
                throw .failed("replay of \(report.run) diverged")
            }
        case .bindingProxy:
            try await backend.serveBindingProxy(
                run: values["run"] ?? "", binding: values["binding"] ?? "")
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings of the improvement-loop view models.
enum ImprovementText {
    static func imported(_ row: CasebookRow) -> [String] {
        let version = short(row.version)
        return [
            "imported \(row.cases) cases into \(row.name) for \(row.steward) (version \(version))"
        ]
    }

    static func casebooks(_ rows: [CasebookRow]) -> [String] {
        guard !rows.isEmpty else {
            return ["no casebooks yet; import one with `arya casebook import`"]
        }
        var table = Table(headers: ["name", "steward", "cases", "version"])
        for row in rows {
            table.rows.append([row.name, row.steward, "\(row.cases)", short(row.version)])
        }
        return table.lines
    }

    static func rehearsal(_ report: RehearsalReport) -> [String] {
        var lines = [
            "rehearsal \(report.rehearsal): \(report.passed) of \(report.total) cases pass "
                + "(score \(percent(report.score))) on \(report.casebook)"
        ]
        for item in report.cases where !item.passed || item.leak {
            var line = "  \(item.id)  score \(percent(item.score))"
            if item.leak { line += "  leak: read a tool the case has no answer for" }
            lines.append(line)
        }
        return lines
    }

    static func correction(_ report: CorrectionReport) -> [String] {
        var parts = ["corrected \(report.case) for \(report.steward)"]
        if let choice = report.choice { parts.append("expected choice is now \(choice)") }
        if let memory = report.memory { parts.append("noted as \(memory)") }
        return [parts.joined(separator: "; ")]
    }

    static func proposals(_ rows: [ProposalRow]) -> [String] {
        guard !rows.isEmpty else { return ["no proposals"] }
        var table = Table(headers: ["id", "steward", "kind", "state", "baseline", "candidate"])
        for row in rows {
            table.rows.append([
                row.id, row.steward, row.kind, row.state.rawValue,
                row.baseline.map(percent) ?? "-", row.candidate.map(percent) ?? "-",
            ])
        }
        return table.lines
    }

    static func metrics(_ series: [MetricSeries]) -> [String] {
        guard !series.isEmpty else { return ["no metrics recorded yet"] }
        return series.flatMap { item -> [String] in
            let target = item.target.map { ", target \($0)" } ?? ""
            let unit = item.unit.map { " (\($0)\(target))" } ?? ""
            return ["\(item.metric)\(unit): \(item.points.count) point(s)"]
                + item.points.suffix(10).map { "  \($0.at)  \($0.value)" }
        }
    }

    static func memory(_ rows: [MemoryRow]) -> [String] {
        guard !rows.isEmpty else { return ["no memory notes"] }
        return rows.map { row in
            let tags = row.tags.isEmpty ? "" : " [\(row.tags.joined(separator: ", "))]"
            let retracted = row.retracted ? " (retracted)" : ""
            return "\(row.id)  \(row.author)\(tags)\(retracted): \(row.text)"
        }
    }

    static func routines(_ rows: [RoutineRow]) -> [String] {
        guard !rows.isEmpty else { return ["no routines"] }
        var table = Table(headers: ["name", "language", "live", "versions"])
        for row in rows {
            table.rows.append([
                row.name, row.language, row.liveVersion.map(short) ?? "-", "\(row.versions)",
            ])
        }
        return table.lines
    }

    static func replay(_ report: ReplayReport) -> [String] {
        guard !report.divergences.isEmpty else {
            return ["replay of \(report.run): \(report.events) events, zero divergence"]
        }
        var lines = ["replay of \(report.run) diverged in \(report.divergences.count) event(s):"]
        for item in report.divergences {
            lines.append("  seq \(item.seq) \(item.type) \(item.field)")
            lines.append("    recorded: \(item.recorded)")
            lines.append("    replayed: \(item.replayed)")
        }
        return lines
    }

    /// The first 12 characters of a content hash.
    static func short(_ hash: String) -> String { String(hash.prefix(12)) }

    static func percent(_ score: Double) -> String { "\(Int((score * 100).rounded()))%" }
}
