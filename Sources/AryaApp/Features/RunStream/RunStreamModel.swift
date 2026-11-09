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
    /// Why the policy held it, in words: the charter rule's note, else a sentence.
    var policyText: String = ""
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
        let proxied = events.contains { $0.run == run && $0.type == "run.tool.call" }
        var projector = RunStreamProjector(proxiedTools: proxied)
        for event in events where event.run == run {
            projector.apply(event)
        }
        var steps = projector.steps
        if let steward = projector.steward,
            steps.contains(where: { if case .action = $0.kind { true } else { false } })
        {
            // The charter live when the run started classified its actions (decision 0032).
            let start = events.first { $0.run == run }?.seq ?? Int.max
            let charter = LiveCharter.find(
                events: events.filter { $0.seq < start }, steward: steward)?.charter
            for index in steps.indices {
                guard case .action(var action) = steps[index].kind, !action.rule.isEmpty else {
                    continue
                }
                action.policyText = PolicyText.describe(action, charter: charter)
                steps[index].kind = .action(action)
            }
        }
        return RunStream(
            run: run, steward: projector.steward, steps: steps,
            status: projector.status, input: projector.input)
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
    private var toolIndex: [String: Int] = [:]
    private var actionIndex: [String: Int] = [:]
    private var approvalAction: [String: String] = [:]
    private var toolStart: [String: Date] = [:]

    mutating func apply(_ event: FeatureEvent) {
        steward = steward ?? event.steward
        let p = event.payload
        switch event.type {
        case "run.started":
            // `trigger` is a string; newer runs record `input: {kind, text}` instead.
            input = p["input"]?["text"]?.string ?? p["input"]?.string
            let trigger = p["trigger"]?.string ?? p["input"]?["kind"]?.string ?? "manual"
            add(event, .started(trigger: trigger))
        case "run.adapter.event": applyAdapter(event)
        case "run.tool.call": applyToolCall(event, p)
        case "run.tool.result": applyToolResult(event, p)
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
        case "run.finished":
            let state = p["status"]?.string ?? "completed"
            let summary = p["summary"]?.string ?? ""
            status = .finished(status: state, summary: summary)
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
        default: break
        }
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
            update(p["action"]?.string, .executed(output: p["output"]?.compactOutput ?? ""))
            attachRoutine(p["action"]?.string, p["output"])
        case "action.failed":
            update(p["action"]?.string, .failed(error: p["error"]?.string ?? "unknown error"))
            attachRoutine(p["action"]?.string, p["output"])
        case "action.rejected":
            update(p["action"]?.string, .rejected(rule: p["reason"]?.string ?? "policy: deny"))
        default: break
        }
    }

    private mutating func update(_ action: String?, _ outcome: ActionOutcome) {
        guard let action, let index = actionIndex[action],
            case .action(var step) = steps[index].kind
        else { return }
        step.outcome = outcome
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

/// Why the policy held an action, in the workspace's words: the holding charter rule's
/// `note`, else a sentence naming the rule or the default.
enum PolicyText {
    static func describe(_ action: ProposedActionStep, charter: FeatureJSON?) -> String {
        let label = action.kind.prefix(1).uppercased() + action.kind.dropFirst()
        let reason = action.rule
        if reason.hasPrefix("rule:") {
            let name = String(reason.dropFirst("rule:".count))
            let rule = charter?["policy"]?["rules"]?.array?.first { rule in
                rule["action"]?.string == name
                    && (rule["binding"]?.string == nil || rule["binding"]?.string == action.binding)
            }
            if let note = rule?["note"]?.string, !note.isEmpty { return note }
            return "\(label) actions need approval."
        }
        if reason.hasPrefix("autonomy:") { return autonomy(reason) }
        switch reason {
        case "default": return "Actions the charter does not name need approval."
        case "routine_default":
            return "A routine version needs approval until the charter names it."
        default: return "The steward's policy holds this action for a person."
        }
    }

    /// `autonomy:<level>:<risk>` (decision 0037) as the workspace words it.
    static func autonomy(_ reason: String) -> String {
        let parts = reason.split(separator: ":").map(String.init)
        let level = parts.count > 1 ? parts[1] : ""
        let risk = parts.count > 2 ? parts[2] : nil
        let risky = risk.map { "this one is \($0) risk" }
        switch level {
        case "observe":
            return "This steward only observes, so it takes no action without a person."
        case "suggest":
            return "This steward only suggests changes, so a person approves each action."
        case "act_low":
            return "This steward acts on low-risk actions only; "
                + (risky ?? "this one may not be") + ", so it asks you."
        case "act_medium":
            return "This steward acts on low- and medium-risk actions only; "
                + (risky ?? "this one may be high risk") + ", so it asks you."
        default:
            return "This steward's autonomy level holds this action for a person."
        }
    }
}
