import Foundation

/// Where a run stands.
enum RunStatus: Hashable, Sendable {
    case running
    case finished(status: String, summary: String)
    case failed(reason: String)

    /// The word shown next to the status dot.
    var word: String {
        switch self {
        case .running: return "running"
        case .finished(let status, _): return status
        case .failed: return "failed"
        }
    }
}

/// A tool call joined with its result.
struct ToolCallStep: Hashable, Sendable {
    var callID: String
    var tool: String
    var input: FeatureJSON
    var output: FeatureJSON?
    var isError = false
    var durationSeconds: Double?
    /// The binding that served the call, when the binding proxy recorded it.
    var binding: String? = nil
    /// Who answered: `live`, `recorded` (rehearsal or replay), or `unanswered` (a leak).
    var source: String? = nil
}

/// What became of a proposed action.
enum ActionOutcome: Hashable, Sendable {
    case proposed
    case awaitingApproval(approval: String)
    case approved(approval: String)
    case executed(output: String)
    case failed(error: String)
    case rejected(rule: String)
    case denied(approval: String, reason: String)
}

/// An action the steward proposed, with its policy and outcome.
struct ProposedActionStep: Hashable, Sendable {
    var actionID: String
    var kind: String
    var target: String
    var summary: String
    var rationale: String
    var policy: String
    /// The policy rule that classified the action, for example `deny close`.
    var rule: String = ""
    var outcome: ActionOutcome
    /// The binding the action goes through, for example `tracker`.
    var binding: String? = nil
    /// What running the routine produced, for a `routine` action that ran.
    var routine: RoutineRun? = nil
    /// The action's parameters, for example a reply's `text`.
    var params: FeatureJSON = [:]
    /// Executed as a dry run (`action.executed` output `{dryRun: true}`): drafted, not applied.
    var dryRun = false

    /// The full content the action would write, for actions that carry text (a reply, a
    /// comment, a message), shown in full on its approval.
    var content: String? {
        for key in ["text", "body", "message", "comment"] {
            if let text = params[key]?.string, !text.isEmpty { return text }
        }
        return nil
    }

    /// The other parameters as `key: value` lines, for actions without text content.
    var paramLines: [String] {
        guard case .object(let members) = params else { return [] }
        return members.keys.sorted().compactMap { key in
            guard content == nil || !["text", "body", "message", "comment"].contains(key),
                let value = members[key]
            else { return nil }
            return "\(key): \(value.string ?? value.compactText)"
        }
    }

    /// How much harm a wrong action could do, from its kind.
    var risk: ActionRisk { ActionRisk(kind: kind) }

    /// The policy reason in words: `rule:reply` as "rule reply".
    var policyReason: String { rule.replacingOccurrences(of: ":", with: " ") }
}

/// How much harm a wrong action of a kind could do: low for reversible bookkeeping (labels,
/// routing), medium for writes people read (replies, comments, assignments), high for actions
/// that are hard to undo (closing, deleting, merging, running code). Unknown kinds are medium.
enum ActionRisk: String, Hashable, Sendable {
    case low, medium, high

    init(kind: String) {
        switch kind {
        case "label", "unlabel", "route", "tag", "untag", "move": self = .low
        case "close", "delete", "merge", "routine", "refund", "pay", "publish": self = .high
        default: self = .medium
        }
    }
}

/// A routine action's result: the runtime's `RoutineOutcome`, recorded as the executor output
/// of `action.executed` (exit status 0) or `action.failed`.
struct RoutineRun: Hashable, Sendable {
    var name: String
    var version: String
    /// `exited`, `signaled`, or `timed_out`.
    var status: String
    var exitCode: Int?
    var signal: Int?
    var stdout: String
    var stderr: String
    var truncated: Bool

    init?(_ json: FeatureJSON?) {
        guard let json, let name = json["name"]?.string, let version = json["version"]?.string,
            let status = json["status"]?.string
        else { return nil }
        self.name = name
        self.version = version
        self.status = status
        exitCode = json["exitCode"]?.number.map { Int($0) }
        signal = json["signal"]?.number.map { Int($0) }
        stdout = json["stdout"]?.string ?? ""
        stderr = json["stderr"]?.string ?? ""
        truncated = json["stdoutTruncated"]?.bool == true || json["stderrTruncated"]?.bool == true
    }
}

/// One step in a run stream.
struct StreamStep: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case started(trigger: String)
        case message(role: String, text: String)
        case thinking(text: String)
        case status(state: String, detail: String)
        case error(message: String)
        case toolCall(ToolCallStep)
        case decision(id: String, choice: String, rationale: String, alternatives: [String])
        case action(ProposedActionStep)
        case finished(status: String, summary: String)
        case failed(reason: String)
        /// Work handed to a crew child run (`run.delegated`), with the child's own steps.
        indirect case delegated(DelegationStep)
    }

    /// The id of the event that opened the step.
    var id: String
    /// The 1-based position in the stream, shown in the gutter.
    var number: Int
    var at: Date
    var kind: Kind
}

/// A run as a readable record: its steps in order and its status.
struct RunStream: Hashable, Sendable {
    var run: String
    var steward: String?
    var steps: [StreamStep]
    var status: RunStatus
    /// The text the run started with, for example the message it acts on.
    var input: String? = nil
    /// Adapter, effort, duration, tokens, and cost, for the run header.
    var facts = RunMetrics()
    /// The input read in plain words: a crew report, structured data, or text.
    var reading: RunInput? = nil
    /// How far a live run has got; nil once it ended.
    var progress: RunProgress? = nil

    /// The run in one line: its summary once finished, else its input, else its id.
    var title: String {
        if case .finished(_, let summary) = status, !summary.isEmpty { return summary }
        if let input, let line = input.split(separator: "\n").first { return String(line) }
        return run
    }

    /// Projects one run's events into a stream. Events of other runs are ignored. Adapter
    /// notifications come from `run.adapter.event`, which holds each raw JSON-RPC line. Tool
    /// calls come from the adapter's `tool_call` and `tool_result` notifications, unless the
    /// run has `run.tool.call` events (the binding proxy's record), which then win.
    static func build(events: [FeatureEvent], run: String) -> RunStream {
        // The runtime's live step records win over the proxy's and the adapter's tool records.
        let stepped = events.contains { $0.run == run && $0.type == "run.step.started" }
        let proxied =
            stepped || events.contains { $0.run == run && $0.type == "run.tool.call" }
        var projector = RunStreamProjector(proxiedTools: proxied, steppedTools: stepped)
        for event in events where event.run == run {
            projector.apply(event)
        }
        let steps = projector.steps.map { step -> StreamStep in
            guard case .delegated(var delegation) = step.kind, let child = delegation.child,
                child != run
            else { return step }
            delegation.attach(child: RunStream.build(events: events, run: child), events: events)
            var filled = step
            filled.kind = .delegated(delegation)
            return filled
        }
        var facts = projector.facts
        // One duration source: run.started to run.finished (or run.failed).
        let mine = events.filter { $0.run == run }
        if let start = mine.first(where: { $0.type == "run.started" })?.at,
            let end = mine.last(where: { $0.type == "run.finished" || $0.type == "run.failed" })?.at
        {
            facts.seconds = end.timeIntervalSince(start)
        }
        let reading = projector.input.map {
            RunInput.build(kind: projector.inputKind, text: $0, events: events)
        }
        let progress =
            projector.status == .running
            ? RunProgress.build(
                events: events, run: run, steward: projector.steward,
                done: RunThreadText.visible(steps).count, reported: projector.reported) : nil
        return RunStream(
            run: run, steward: projector.steward, steps: steps,
            status: projector.status, input: projector.input, facts: facts, reading: reading,
            progress: progress)
    }

    /// The approval ids in this run still waiting for a person.
    var pendingApprovals: [String] {
        steps.compactMap { step in
            if case .action(let action) = step.kind,
                case .awaitingApproval(let approval) = action.outcome
            {
                return approval
            }
            return nil
        }
    }
}

/// Folds events into steps, keeping indexes so later events update earlier steps.
private struct RunStreamProjector {
    var proxiedTools: Bool
    var steps: [StreamStep] = []
    var status: RunStatus = .running
    var steward: String?
    var input: String?
    var inputKind: String?
    var facts = RunMetrics()
    private var toolIndex: [String: Int] = [:]
    private var actionIndex: [String: Int] = [:]
    private var approvalAction: [String: String] = [:]
    private var toolStart: [String: Date] = [:]
    var steppedTools = false
    /// The adapter's own count (`progress` event): done of total.
    var reported: (done: Int, total: Int)?

    mutating func apply(_ event: FeatureEvent) {
        steward = steward ?? event.steward
        let p = event.payload
        switch event.type {
        case "run.started":
            // `trigger` is a string; newer runs record `input: {kind, text}` instead.
            input = p["input"]?["text"]?.string ?? p["input"]?.string
            inputKind = p["input"]?["kind"]?.string
            facts.adapter = p["adapter"]?.string
            facts.effort = p["effort"]?.string
            let trigger = p["trigger"]?.string ?? p["input"]?["kind"]?.string ?? "manual"
            add(event, .started(trigger: trigger))
        case "run.adapter.event": applyAdapter(event)
        case "run.step.started":
            let text = p["input"]?.string ?? ""
            let input =
                text.data(using: .utf8).flatMap {
                    try? JSONDecoder().decode(FeatureJSON.self, from: $0)
                }
                ?? .string(text)
            applyToolCall(
                event, ["id": p["step"] ?? .null, "tool": p["tool"] ?? .null, "input": input])
        case "run.step.output": applyStepOutput(p)
        case "run.step.finished": applyStepFinished(p)
        case "run.tool.call" where !steppedTools: applyToolCall(event, p)
        case "run.tool.result" where !steppedTools: applyToolResult(event, p)
        case "run.decision":
            // `{decision: RecordedDecision}`; older recordings put the fields at the top.
            let d = p["decision"] ?? p
            add(
                event,
                .decision(
                    id: d["id"]?.string ?? event.id, choice: d["choice"]?.string ?? "",
                    rationale: d["rationale"]?.string ?? "",
                    alternatives: d["alternatives"]?.strings ?? []))
        case "action.proposed": applyProposed(event)
        case "run.delegated": add(event, .delegated(DelegationStep(p)))
        case "run.finished":
            let state = p["status"]?.string ?? "completed"
            let summary = p["summary"]?.string ?? ""
            status = .finished(status: state, summary: summary)
            if let cost = p["cost"] {
                let tokens =
                    (cost["inputTokens"]?.number ?? 0) + (cost["outputTokens"]?.number ?? 0)
                facts.tokens = Int(tokens)
                facts.costMicros = cost["costMicros"]?.number.map(Int.init)
            }
            facts.decisions = p["counts"]?["decisions"]?.number.map(Int.init)
            facts.actions = p["counts"]?["actions"]?.number.map(Int.init)
            add(event, .finished(status: state, summary: summary))
        case "run.failed":
            let detail = p["detail"]?.string.map { " (\($0))" } ?? ""
            let reason = (p["reason"]?.string ?? "unknown") + detail
            status = .failed(reason: reason)
            add(event, .failed(reason: reason))
        default: applyOutcome(event)
        }
    }

    private mutating func add(_ event: FeatureEvent, _ kind: StreamStep.Kind) {
        steps.append(StreamStep(id: event.id, number: steps.count + 1, at: event.at, kind: kind))
    }

    /// Reads a `run/event` notification out of the recorded JSON-RPC line; other lines
    /// (requests, responses, `run/result`) are not steps.
    private mutating func applyAdapter(_ event: FeatureEvent) {
        let message = event.payload["message"]
        guard message?["method"]?.string == "run/event",
            let inner = message?["params"]?["event"]
        else { return }
        switch inner["kind"]?.string {
        case "tool_call" where !proxiedTools: applyToolCall(event, inner)
        case "tool_result" where !proxiedTools: applyToolResult(event, inner)
        case "message":
            add(
                event,
                .message(
                    role: inner["role"]?.string ?? "assistant", text: inner["text"]?.string ?? ""))
        case "thinking": add(event, .thinking(text: inner["text"]?.string ?? ""))
        case "status":
            add(
                event,
                .status(
                    state: inner["state"]?.string ?? "", detail: inner["detail"]?.string ?? ""))
        case "error": add(event, .error(message: inner["message"]?.string ?? ""))
        case "progress":
            if let done = inner["done"]?.number, let total = inner["total"]?.number, total > 0 {
                reported = (Int(done), Int(total))
            }
        default: break
        }
    }

    /// A chunk of a live step's output, appended in order.
    private mutating func applyStepOutput(_ p: FeatureJSON) {
        guard let call = p["step"]?.string, let index = toolIndex[call],
            case .toolCall(var step) = steps[index].kind
        else { return }
        let sofar = step.output?.string ?? ""
        step.output = .string(sofar + (p["text"]?.string ?? ""))
        steps[index].kind = .toolCall(step)
    }

    private mutating func applyStepFinished(_ p: FeatureJSON) {
        guard let call = p["step"]?.string, let index = toolIndex[call],
            case .toolCall(var step) = steps[index].kind
        else { return }
        step.output = step.output ?? .string("")
        step.isError = p["ok"]?.bool == false
        step.durationSeconds = p["millis"]?.number.map { $0 / 1000 }
        steps[index].kind = .toolCall(step)
    }

    private mutating func applyToolCall(_ event: FeatureEvent, _ p: FeatureJSON) {
        let call = p["id"]?.string ?? event.id
        toolIndex[call] = steps.count
        toolStart[call] = event.at
        let step = ToolCallStep(
            callID: call, tool: p["tool"]?.string ?? "tool", input: p["input"] ?? .null,
            binding: p["binding"]?.string)
        add(event, .toolCall(step))
    }

    private mutating func applyToolResult(_ event: FeatureEvent, _ p: FeatureJSON) {
        guard let call = p["id"]?.string, let index = toolIndex[call],
            case .toolCall(var step) = steps[index].kind
        else { return }
        step.output = p["output"] ?? .null
        step.isError = p["isError"]?.bool ?? false
        step.source = p["source"]?.string
        if let start = toolStart[call] {
            step.durationSeconds = p["durationSeconds"]?.number ?? event.at.timeIntervalSince(start)
        }
        steps[index].kind = .toolCall(step)
    }

    /// `action.proposed` is `{action: ProposedAction, disposition, reason}`.
    private mutating func applyProposed(_ event: FeatureEvent) {
        let p = event.payload
        let action = p["action"] ?? [:]
        let id = action["id"]?.string ?? event.id
        let kind = action["kind"]?.string ?? "action"
        let target = action["target"]?.string ?? ""
        let step = ProposedActionStep(
            actionID: id, kind: kind, target: target,
            summary: ApprovalText.summary(kind: kind, target: target),
            rationale: action["rationale"]?.string ?? "",
            policy: p["disposition"]?.string ?? "ask", rule: p["reason"]?.string ?? "",
            outcome: .proposed, binding: action["binding"]?.string, params: action["params"] ?? [:])
        actionIndex[id] = steps.count
        add(event, .action(step))
    }

    private mutating func applyOutcome(_ event: FeatureEvent) {
        let p = event.payload
        switch event.type {
        case "approval.requested":
            guard let approval = p["approval"]?.string, let action = p["action"]?["id"]?.string
            else { return }
            approvalAction[approval] = action
            update(action, .awaitingApproval(approval: approval))
        case "approval.granted":
            guard let approval = p["approval"]?.string, let action = approvalAction[approval]
            else { return }
            update(action, .approved(approval: approval))
        case "approval.denied", "approval.expired":
            guard let approval = p["approval"]?.string, let action = approvalAction[approval]
            else { return }
            let reason = p["note"]?.string ?? (event.type == "approval.expired" ? "expired" : "")
            update(action, .denied(approval: approval, reason: reason))
        case "action.executed":
            let dry = p["dryRun"]?.bool == true || p["output"]?["dryRun"]?.bool == true
            update(
                p["action"]?.string,
                .executed(output: dry ? "" : p["output"]?.compactOutput ?? ""), dryRun: dry)
            attachRoutine(p["action"]?.string, p["output"])
        case "action.failed":
            update(p["action"]?.string, .failed(error: p["error"]?.string ?? "unknown error"))
            attachRoutine(p["action"]?.string, p["output"])
        case "action.rejected":
            update(p["action"]?.string, .rejected(rule: p["reason"]?.string ?? "policy: deny"))
        default: break
        }
    }

    private mutating func update(_ action: String?, _ outcome: ActionOutcome, dryRun: Bool = false)
    {
        guard let action, let index = actionIndex[action],
            case .action(var step) = steps[index].kind
        else { return }
        step.outcome = outcome
        step.dryRun = dryRun
        steps[index].kind = .action(step)
    }

    private mutating func attachRoutine(_ action: String?, _ output: FeatureJSON?) {
        guard let action, let index = actionIndex[action], let run = RoutineRun(output),
            case .action(var step) = steps[index].kind, step.kind == "routine"
        else { return }
        step.routine = run
        steps[index].kind = .action(step)
    }
}

extension FeatureJSON {
    /// A string as itself, anything else as compact JSON.
    fileprivate var compactOutput: String { string ?? compactText }
}

/// The two sides of the run's split pane.
enum StreamPane: Hashable, Sendable {
    /// Conversation, reasoning, status, and decisions: compact rows on the left.
    case conversation
    /// Tool calls, results, and actions: compact cards on the right.
    case work
}

extension StreamStep {
    var pane: StreamPane {
        switch kind {
        case .toolCall, .action: return .work
        default: return .conversation
        }
    }

    /// The approval this step is waiting on, if any.
    var pendingApproval: String? {
        if case .action(let action) = kind, case .awaitingApproval(let id) = action.outcome {
            return id
        }
        return nil
    }
}

extension RunStream {
    var conversation: [StreamStep] { steps.filter { $0.pane == .conversation } }
    /// Work steps waiting for a person, pinned at the top of the work pane.
    var waiting: [StreamStep] { steps.filter { $0.pendingApproval != nil } }
    /// The other work steps, in order.
    var work: [StreamStep] { steps.filter { $0.pane == .work && $0.pendingApproval == nil } }
}

/// A delegation to a crew child run: what was asked, the budget the child ran with (capped at
/// the parent's, decision 0043), or why it was refused; then the child's steps and result.
struct DelegationStep: Hashable, Sendable {
    var delegation: String
    var title: String
    var child: String?
    var adapter: String?
    var effort: String?
    var limits: FeatureJSON?
    var refused: String?
    var childStatus: RunStatus?
    var childSteps: [StreamStep] = []
    var seconds: Double?

    init(_ payload: FeatureJSON) {
        delegation = payload["delegation"]?.string ?? ""
        title = payload["title"]?.string ?? ""
        child = payload["child"]?.string
        adapter = payload["adapter"]?.string
        effort = payload["effort"]?.string
        limits = payload["limits"]
        refused = payload["refused"]?.string
    }

    mutating func attach(child stream: RunStream, events: [FeatureEvent]) {
        guard !stream.steps.isEmpty else { return }
        childStatus = stream.status
        childSteps = stream.steps
        let times = events.filter { $0.run == stream.run }.map(\.at)
        if stream.status != .running, let first = times.min(), let last = times.max() {
            seconds = last.timeIntervalSince(first)
        }
    }
}

/// Words for crew lines in the run thread.
enum CrewText {
    /// "drafted the refund reply · child run · 2.1 s" (the status is the line's mark), a
    /// failure word when it did not complete, or why it was refused.
    static func line(_ step: DelegationStep) -> String {
        let title = step.title.isEmpty ? step.delegation : step.title
        if let refused = step.refused { return "\(title) · refused: \(refusal(refused))" }
        var parts = [title, "child run"]
        switch step.childStatus {
        case .finished(let status, _)?:
            if status != "completed" { parts.append(status) }
            if let seconds = step.seconds { parts.append(duration(seconds)) }
        case .failed?: parts.append("failed")
        case .running?: parts.append("running")
        case nil: parts.append(step.child == nil ? "not started" : "starting")
        }
        return parts.joined(separator: " · ")
    }

    /// The child's budget as it ran: "adapter fake · effort low · 4 turns · 60 s · $0.20".
    static func budget(_ step: DelegationStep) -> String? {
        var parts: [String] = []
        if let adapter = step.adapter { parts.append("adapter \(adapter)") }
        if let effort = step.effort { parts.append("effort \(effort)") }
        if let turns = step.limits?["maxTurns"]?.number { parts.append("\(Int(turns)) turns") }
        if let timeout = step.limits?["timeoutSeconds"]?.number {
            parts.append("\(Int(timeout)) s")
        }
        if let micros = step.limits?["maxCostMicros"]?.number {
            parts.append(String(format: "$%.2f", micros / 1_000_000))
        }
        return parts.isEmpty ? nil : "budget: " + parts.joined(separator: " · ")
    }

    /// The child's result: its summary, else its failure.
    static func result(_ step: DelegationStep) -> String? {
        switch step.childStatus {
        case .finished(_, let summary)?: summary.isEmpty ? nil : summary
        case .failed(let reason)?: "Failed: \(reason)"
        default: nil
        }
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 60
            ? String(format: "%.1f s", seconds) : "\(Int(seconds / 60)) min \(Int(seconds) % 60) s"
    }

    /// `adapter_not_allowed:x` -> "adapter x is not in the crew"; `unknown_effort:y` alike.
    static func refusal(_ reason: String) -> String {
        let parts = reason.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return reason }
        switch parts[0] {
        case "adapter_not_allowed": return "adapter \(parts[1]) is not in the crew"
        case "unknown_effort": return "unknown effort \(parts[1])"
        default: return reason
        }
    }
}

/// What a run ran with and what it took, shown in mono in the run header.
struct RunMetrics: Hashable, Sendable {
    var adapter: String?
    var effort: String?
    var seconds: Double?
    var tokens: Int?
    var costMicros: Int?
    var decisions: Int?
    var actions: Int?

    /// "fake-triage · effort medium · 2.4 s · 1 decision · 3 actions · 12,840 tokens ·
    /// $0.0012". Duration and cost read "—" when unknown (a running run, an adapter that
    /// reports no usage), never "0.0 s" or "$0".
    var text: String {
        var parts: [String] = []
        if let adapter { parts.append(adapter) }
        if let effort { parts.append("effort \(effort)") }
        parts.append(seconds.map(FeatureTime.duration) ?? "duration —")
        if let decisions { parts.append(RunMetrics.count(decisions, "decision")) }
        if let actions { parts.append(RunMetrics.count(actions, "action")) }
        if let tokens, tokens > 0 { parts.append("\(RunMetrics.grouped(tokens)) tokens") }
        if let costMicros, costMicros > 0 {
            parts.append(RunMetrics.dollars(costMicros))
        } else {
            parts.append("cost —")
        }
        return parts.joined(separator: " · ")
    }

    /// "1 decision", "3 actions".
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// 12840 -> "12,840".
    static func grouped(_ number: Int) -> String {
        var digits = String(number)
        var index = digits.count - 3
        while index > 0 {
            digits.insert(",", at: digits.index(digits.startIndex, offsetBy: index))
            index -= 3
        }
        return digits
    }

    static func dollars(_ micros: Int) -> String {
        let value = Double(micros) / 1_000_000
        return value > 0 && value < 0.01
            ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}

/// A run's input in plain words. A crew report (`join`) reads as one sentence per child with a
/// link to its run; other structured input reads as a one-line summary; raw text stays behind
/// "Show raw".
struct RunInput: Hashable, Sendable {
    struct Child: Hashable, Sendable {
        var run: String?
        var title: String
        /// "Drafted the refund reply for MSG-203. 1 action proposed for approval."
        var sentence: String
    }

    enum Body: Hashable, Sendable {
        case text(String)
        case crew([Child])
        case structured(String)
    }

    var body: Body
    /// The run that delegated the work this run checks, for "checks the delegated work from".
    var parent: (run: String, title: String)? {
        guard let parentRun else { return nil }
        return (parentRun, parentTitle ?? parentRun)
    }
    var parentRun: String?
    var parentTitle: String?
    /// The raw input, shown only behind "Show raw"; nil for plain text.
    var raw: String?

    static func build(kind: String?, text: String, events: [FeatureEvent]) -> RunInput {
        let json = text.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(FeatureJSON.self, from: $0)
        }
        guard let json, case .object(let members) = json else {
            return RunInput(body: .text(text))
        }
        if kind == "join" || members["children"] != nil,
            case .array(let list)? = members["children"]
        {
            let children = list.map(child)
            let parentRun = children.lazy.compactMap(\.run).compactMap {
                RunInput.delegator(of: $0, events: events)
            }.first
            let parentTitle = parentRun.map {
                RunStream.build(events: events, run: $0).title
            }
            return RunInput(
                body: .crew(children), parentRun: parentRun, parentTitle: parentTitle,
                raw: RunInput.pretty(text))
        }
        return RunInput(body: .structured(summary(members)), raw: RunInput.pretty(text))
    }

    private static func child(_ value: FeatureJSON) -> Child {
        let title = value["title"]?.string ?? value["delegation"]?.string ?? "Child run"
        var sentence = value["summary"]?.string ?? title
        if case .array(let actions)? = value["actions"], !actions.isEmpty {
            let count = RunMetrics.count(actions.count, "action")
            sentence += " \(count) proposed for approval."
        } else if let status = value["status"]?.string, status != "completed" {
            sentence += " Ended \(status)."
        }
        return Child(run: value["run"]?.string, title: title, sentence: sentence)
    }

    /// "Structured input: 3 fields (customer, order, reason)".
    private static func summary(_ members: [String: FeatureJSON]) -> String {
        let keys = members.keys.sorted()
        let shown = keys.prefix(4).joined(separator: ", ")
        let more = keys.count > 4 ? ", …" : ""
        return "Structured input: \(RunMetrics.count(keys.count, "field")) (\(shown)\(more))"
    }

    /// The raw input indented for reading; unchanged when it is not JSON.
    static func pretty(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let out = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: out, encoding: .utf8)
        else { return text }
        return string
    }

    /// The run whose `run.delegated` started `child`.
    static func delegator(of child: String, events: [FeatureEvent]) -> String? {
        events.first { $0.type == "run.delegated" && $0.payload["child"]?.string == child }?.run
    }
}

/// A live run's progress: events so far against the steward's usual run, and time since start.
/// Steps are counted as ledger events other than adapter traffic, the same way for both.
struct RunProgress: Hashable, Sendable {
    var done: Int
    /// The median count over the steward's finished runs; nil before any finished.
    var expected: Int?
    var started: Date

    /// "3 of ~6 steps · 4.2 s"; "3 steps · 4.2 s" without history. A run past its usual length
    /// reads "7 of ~6".
    func text(now: Date) -> String {
        let steps = expected.map { "\(done) of ~\($0) steps" } ?? RunMetrics.count(done, "step")
        return "\(steps) · \(FeatureTime.duration(max(0, now.timeIntervalSince(started))))"
    }

    /// Done against expected, held under 1 while the run is still going.
    var fraction: Double {
        guard let expected, expected > 0 else { return 0.5 }
        return min(Double(done) / Double(expected), 0.95)
    }

    /// `done` is the thread's visible step count; `expected` the median of the same count over
    /// the steward's last ten finished runs.
    static func build(
        events: [FeatureEvent], run: String, steward: String?, done: Int,
        reported: (done: Int, total: Int)? = nil
    ) -> RunProgress? {
        guard let started = events.first(where: { $0.run == run && $0.type == "run.started" })?.at
        else { return nil }
        // The adapter's own count is better than an estimate from history.
        if let reported {
            return RunProgress(done: reported.done, expected: reported.total, started: started)
        }
        let finished = events.filter {
            $0.type == "run.finished" && $0.steward == steward && $0.run != run
        }
        .suffix(10).compactMap(\.run)
        let history = finished.map {
            RunThreadText.visible(RunStream.build(events: events, run: $0).steps).count
        }
        .sorted()
        let expected = history.isEmpty ? nil : history[history.count / 2]
        return RunProgress(done: done, expected: expected, started: started)
    }
}

/// How an action's result reads: a reply that was sent, or drafted in a dry run.
extension ActionWords {
    static func isMessage(_ kind: String) -> Bool {
        ["reply", "comment", "message", "send"].contains(kind)
    }

    /// "sent", "applied", "drafted, not sent (dry run)", "not applied (dry run)".
    static func done(_ action: ProposedActionStep) -> String {
        if action.dryRun {
            return isMessage(action.kind) ? "drafted, not sent (dry run)" : "not applied (dry run)"
        }
        return isMessage(action.kind) ? "sent" : "applied"
    }

    static func outcome(_ action: ProposedActionStep) -> String {
        if case .executed = action.outcome { return done(action) }
        return RunWork.outcomeWord(action.outcome)
    }
}
