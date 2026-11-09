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
        return RunStream(
            run: run, steward: projector.steward, steps: projector.steps,
            status: projector.status)
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
    private var toolIndex: [String: Int] = [:]
    private var actionIndex: [String: Int] = [:]
    private var approvalAction: [String: String] = [:]
    private var toolStart: [String: Date] = [:]

    mutating func apply(_ event: FeatureEvent) {
        steward = steward ?? event.steward
        let p = event.payload
        switch event.type {
        case "run.started":
            add(event, .started(trigger: p["trigger"]?.string ?? "manual"))
        case "run.adapter.event": applyAdapter(event)
        case "run.tool.call": applyToolCall(event, p)
        case "run.tool.result": applyToolResult(event, p)
        case "run.decision":
            add(
                event,
                .decision(
                    id: p["id"]?.string ?? event.id, choice: p["choice"]?.string ?? "",
                    rationale: p["rationale"]?.string ?? "",
                    alternatives: p["alternatives"]?.strings ?? []))
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
            outcome: .proposed, binding: action["binding"]?.string)
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
        case "action.failed":
            update(p["action"]?.string, .failed(error: p["error"]?.string ?? "unknown error"))
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
}

extension FeatureJSON {
    /// A string as itself, anything else as compact JSON.
    fileprivate var compactOutput: String { string ?? compactText }
}
