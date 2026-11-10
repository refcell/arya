import Arya
import Foundation

/// What `arya findings`, `arya finding resolve`, and `arya template list|use` need from an arya
/// home: proactive findings (runtime decision 0055) and the example stewards to start from.
/// The defaults keep test doubles compiling; they report "not available yet".
protocol FindingTemplateBackend: Sendable {
    func findings(steward: String?, all: Bool) async throws(CLIError) -> [FindingSummary]
    func resolveFinding(_ id: String, resolution: String, note: String?, by person: String)
        async throws(CLIError) -> FindingSummary
    func templates() async throws(CLIError) -> [StewardTemplate]
    func useTemplate(_ template: String, id: String?, name: String?, owner: String?)
        async throws(CLIError) -> StewardDetail
}

extension FindingTemplateBackend {
    func findings(steward: String?, all: Bool) async throws(CLIError) -> [FindingSummary] {
        throw .unavailable("findings")
    }
    func resolveFinding(_ id: String, resolution: String, note: String?, by person: String)
        async throws(CLIError) -> FindingSummary
    {
        throw .unavailable("resolveFinding")
    }
    func templates() async throws(CLIError) -> [StewardTemplate] {
        throw .unavailable("templates")
    }
    func useTemplate(_ template: String, id: String?, name: String?, owner: String?)
        async throws(CLIError) -> StewardDetail
    {
        throw .unavailable("createFromTemplate")
    }
}

extension CommandTable {
    /// Proactive findings and steward templates.
    static let findingsAndTemplates: [CommandSpec] = [
        CommandSpec(
            id: .findings, summary: "List problems and opportunities stewards noticed",
            options: [
                OptionSpec(
                    name: "steward", kind: .value(placeholder: "id"), help: "one steward only"),
                OptionSpec(name: "all", kind: .flag, help: "include resolved findings"),
            ]),
        CommandSpec(
            id: .findingResolve, summary: "Mark a finding acted on or dismissed",
            positionals: [
                PositionalSpec(name: "finding", help: "finding id, <run>/<finding>"),
                PositionalSpec(name: "resolution", help: "acted or dismissed"),
            ],
            options: [
                OptionSpec(name: "note", kind: .value(placeholder: "text"), help: "why"),
                OptionSpec(
                    name: "as", kind: .value(placeholder: "person"),
                    help: "who resolves it (default local)"),
            ]),
        CommandSpec(id: .templateList, summary: "List example stewards to start from"),
        CommandSpec(
            id: .templateUse, summary: "Create a steward from a template",
            positionals: [PositionalSpec(name: "template", help: "template id")],
            options: [
                OptionSpec(
                    name: "id", kind: .value(placeholder: "id"), help: "steward id to use"),
                OptionSpec(
                    name: "name", kind: .value(placeholder: "name"), help: "steward name"),
                OptionSpec(
                    name: "owner", kind: .value(placeholder: "person"), help: "who owns it"),
            ]),
    ]
}

extension CLI {
    /// Runs `findings`, `finding resolve`, `template list`, or `template use`.
    static func dispatchFindingsAndTemplates(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        switch invocation.command {
        case .findings:
            try output.emit(
                try await backend.findings(
                    steward: invocation.values["steward"], all: invocation.flags.contains("all")),
                json: json, text: FindingTemplateText.findings)
        case .findingResolve:
            let resolution = try invocation.positional("resolution")
            guard ["acted", "dismissed"].contains(resolution) else {
                throw .usage("resolution must be acted or dismissed", command: .findingResolve)
            }
            try output.emit(
                try await backend.resolveFinding(
                    try invocation.positional("finding"), resolution: resolution,
                    note: invocation.values["note"], by: invocation.values["as"] ?? "local"),
                json: json, text: { FindingTemplateText.findings([$0]) })
        case .templateList:
            try output.emit(
                try await backend.templates(), json: json, text: FindingTemplateText.templates)
        case .templateUse:
            try output.emit(
                try await backend.useTemplate(
                    try invocation.positional("template"), id: invocation.values["id"],
                    name: invocation.values["name"], owner: invocation.values["owner"]),
                json: json, text: TextRender.steward)
        default:
            throw .usage("unknown command: \(invocation.command.rawValue)")
        }
    }
}

/// Plain-text renderings.
enum FindingTemplateText {
    static func findings(_ findings: [FindingSummary]) -> [String] {
        guard !findings.isEmpty else { return ["no open findings"] }
        return findings.flatMap { finding -> [String] in
            let state = finding.resolution ?? (finding.needsPerson ? "needs you" : "open")
            var lines = ["\(finding.id)  \(finding.kind)  \(state)", "  \(finding.title)"]
            lines += finding.evidence.map { "  - \($0)" }
            if let suggestion = finding.suggestion { lines.append("  suggests: \(suggestion)") }
            return lines
        }
    }

    static func templates(_ templates: [StewardTemplate]) -> [String] {
        templates.map { "\($0.id)  \($0.department)  \($0.summary)" }
    }
}
