import AryaCore
import Foundation

// Composes the instructions a run sees (ARCHITECTURE.md "Runs", step 1). The output is a pure
// function of its inputs and is recorded on `run.started`, so replay and rehearsal see the
// exact same text. Charter order is kept for guardrails and bindings (authors order them by
// importance); memory keeps snapshot order; routines sort by name.

/// The success metric as the instructions describe it.
public struct InstructionMetric: Sendable, Hashable {
    /// Metric name, for example `triaged_within_1h`.
    public var name: String
    /// Unit, for example `ratio`.
    public var unit: String
    /// `up` or `down`: which way is better.
    public var direction: String
    /// Target value, if any.
    public var target: Double?

    /// Creates a metric description.
    public init(name: String, unit: String, direction: String, target: Double? = nil) {
        self.name = name
        self.unit = unit
        self.direction = direction
        self.target = target
    }
}

/// One binding as the instructions describe it.
public struct InstructionBinding: Sendable, Hashable {
    /// Binding id.
    public var id: String
    /// `mcp` or `person`.
    public var kind: String
    /// Read tools the harness may call.
    public var read: [String]
    /// Action kinds the steward may propose through this binding.
    public var actions: [String]

    /// Creates a binding description.
    public init(id: String, kind: String, read: [String] = [], actions: [String] = []) {
        self.id = id
        self.kind = kind
        self.read = read
        self.actions = actions
    }
}

/// One memory note from the run's snapshot.
public struct InstructionNote: Sendable, Hashable {
    /// Note id, so the steward can cite it.
    public var id: String
    /// Note text.
    public var text: String

    /// Creates a note line.
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// One live routine.
public struct InstructionRoutine: Sendable, Hashable {
    /// Routine name, used as `params.name` of a `routine` action.
    public var name: String
    /// Content-hash version.
    public var version: String
    /// One-line description.
    public var summary: String

    /// Creates a routine line.
    public init(name: String, version: String, summary: String) {
        self.name = name
        self.version = version
        self.summary = summary
    }
}

/// Everything the composer needs.
public struct InstructionInputs: Sendable, Hashable {
    /// Steward display name.
    public var name: String
    /// The outcome the steward owns.
    public var outcome: String
    /// Success metric, if the charter names one.
    public var metric: InstructionMetric?
    /// Guardrails in charter order.
    public var guardrails: [String]
    /// Bindings in charter order.
    public var bindings: [InstructionBinding]
    /// Memory snapshot in retrieval order.
    public var memory: [InstructionNote]
    /// Live routines.
    public var routines: [InstructionRoutine]
    /// The steward's current plan.
    public var plan: [PlanItem] = []
    /// How each action kind has worked so far (decision 0053).
    public var effects: [KindEffect] = []

    /// Creates composer inputs.
    public init(
        name: String, outcome: String, metric: InstructionMetric? = nil,
        guardrails: [String] = [], bindings: [InstructionBinding] = [],
        memory: [InstructionNote] = [], routines: [InstructionRoutine] = []
    ) {
        self.name = name
        self.outcome = outcome
        self.metric = metric
        self.guardrails = guardrails
        self.bindings = bindings
        self.memory = memory
        self.routines = routines
    }
}

/// Builds run instructions.
public enum InstructionComposer {
    /// Composes the instructions text. Sections with nothing to say are omitted.
    public static func compose(_ inputs: InstructionInputs) -> String {
        let sections = [
            header(inputs), metric(inputs.metric), guardrails(inputs.guardrails),
            bindings(inputs.bindings), memory(inputs.memory), routines(inputs.routines),
            plan(inputs.plan), effects(inputs.effects), resultRules(),
        ]
        return sections.compactMap { $0 }.joined(separator: "\n\n") + "\n"
    }

    private static func header(_ inputs: InstructionInputs) -> String {
        """
        You are \(oneLine(inputs.name)), a steward in arya. You own this outcome:
        \(oneLine(inputs.outcome))
        """
    }

    private static func metric(_ metric: InstructionMetric?) -> String? {
        guard let metric else { return nil }
        let better = metric.direction == "down" ? "lower is better" : "higher is better"
        var line = "- \(metric.name) (\(metric.unit), \(better))"
        if let target = metric.target { line += ", target \(number(target))" }
        return "## Success metric\n" + line
    }

    private static func guardrails(_ guardrails: [String]) -> String? {
        guard !guardrails.isEmpty else { return nil }
        return "## Guardrails\n" + guardrails.map { "- \(oneLine($0))" }.joined(separator: "\n")
    }

    private static func bindings(_ bindings: [InstructionBinding]) -> String? {
        guard !bindings.isEmpty else { return nil }
        let lines = bindings.map { binding in
            var parts = ["- \(binding.id) (\(binding.kind))"]
            if !binding.read.isEmpty {
                parts.append("read: \(binding.read.joined(separator: ", "))")
            }
            if !binding.actions.isEmpty {
                parts.append("propose: \(binding.actions.joined(separator: ", "))")
            }
            return parts.joined(separator: "; ")
        }
        return "## Bindings\n" + lines.joined(separator: "\n")
    }

    private static func memory(_ notes: [InstructionNote]) -> String? {
        guard !notes.isEmpty else { return nil }
        return "## Memory\n"
            + notes.map { "- [\($0.id)] \(oneLine($0.text))" }
            .joined(separator: "\n")
    }

    private static func routines(_ routines: [InstructionRoutine]) -> String? {
        guard !routines.isEmpty else { return nil }
        let lines = routines.sorted { $0.name < $1.name }.map {
            "- \($0.name) @\($0.version.prefix(12)): \(oneLine($0.summary))"
        }
        return "## Routines\n" + lines.joined(separator: "\n")
    }

    private static func plan(_ items: [PlanItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let lines = items.map { item in
            var line = "- [\(item.id)] \(item.status.rawValue): \(oneLine(item.text))"
            if let rationale = item.rationale { line += " (\(oneLine(rationale)))" }
            return line
        }
        return "## Plan\n" + lines.joined(separator: "\n")
    }

    /// Kinds with results (settled checks or metric credit), so the plan can favor what worked.
    private static func effects(_ effects: [KindEffect]) -> String? {
        let known = effects.filter { $0.resolved + $0.reopened > 0 || $0.credited > 0 }
        guard !known.isEmpty else { return nil }
        return "## What has worked\n" + known.map { "- \($0.line)" }.joined(separator: "\n")
    }

    private static func resultRules() -> String {
        """
        ## How to finish
        Do not change any external system yourself. Read through the tools you were given, then \
        return one result matching the result schema: a summary, your decisions, and the \
        actions you propose. arya applies the approval policy and carries out approved \
        actions. To run a routine, propose an action of kind routine with params.name. Keep a \
        plan toward your outcome: when it changes, return the whole plan (each step with id, \
        text, status pending, in_progress, done, skipped, or blocked, and a rationale). When \
        you notice a problem or an opportunity beyond this input, return it as a finding with \
        evidence and, if useful, a suggested action; set needsPerson when a person must decide.
        """
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

extension InstructionInputs {
    /// Inputs for a charter, with the run's memory snapshot and live routines.
    public init(
        charter: Charter, memory: [InstructionNote] = [], routines: [InstructionRoutine] = []
    ) {
        self.init(
            name: charter.name, outcome: charter.outcome,
            metric: InstructionMetric(
                name: charter.metric.name, unit: charter.metric.unit,
                direction: charter.metric.direction.rawValue, target: charter.metric.target),
            guardrails: charter.guardrails,
            bindings: charter.bindings.map {
                InstructionBinding(
                    id: $0.id, kind: $0.kind.rawValue, read: $0.read, actions: $0.actions)
            },
            memory: memory, routines: routines)
    }
}
