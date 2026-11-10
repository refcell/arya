import Foundation

/// A crew run as a tree: the host run and the delegates it handed work to (`run.delegated`,
/// decisions 0043 and 0053), each with its status, current step, duration, and outcome. It is
/// rebuilt from the store's events, which follow the run live, so it moves while the run runs.
struct CrewFanout: Hashable, Sendable {
    struct Node: Identifiable, Hashable, Sendable {
        enum State: Hashable, Sendable {
            case running, completed, failed, refused, waiting
        }

        var id: String
        var title: String
        var run: String?
        var state: State
        /// "step 3 · tool search…", the latest step; nil before the first.
        var step: String?
        var seconds: Double?
        /// The summary once settled, the refusal, or the failure reason.
        var outcome: String?
    }

    var host: Node
    var children: [Node]

    /// Counts per state for the header: running, done, and failed or refused.
    var tally: (running: Int, done: Int, failed: Int) {
        (
            children.count { $0.state == .running || $0.state == .waiting },
            children.count { $0.state == .completed },
            children.count { $0.state == .failed || $0.state == .refused }
        )
    }

    /// Nil when the run delegated nothing.
    static func build(events: [FeatureEvent], run: String, now: Date) -> CrewFanout? {
        let stream = RunStream.build(events: events, run: run)
        let delegations = stream.steps.compactMap { step -> DelegationStep? in
            if case .delegated(let delegation) = step.kind { return delegation }
            return nil
        }
        guard !delegations.isEmpty else { return nil }
        let host = node(
            id: run, title: stream.title, run: run, status: stream.status, steps: stream.steps,
            seconds: seconds(events: events, run: run, live: stream.status == .running, now: now))
        let children = delegations.map { delegation -> Node in
            if let refused = delegation.refused {
                return Node(
                    id: delegation.delegation, title: delegation.title, run: nil, state: .refused,
                    outcome: refused)
            }
            guard let child = delegation.child, let status = delegation.childStatus else {
                return Node(
                    id: delegation.delegation, title: delegation.title, run: delegation.child,
                    state: .waiting, step: "queued")
            }
            return node(
                id: delegation.delegation, title: delegation.title, run: child, status: status,
                steps: delegation.childSteps,
                seconds: delegation.seconds
                    ?? seconds(events: events, run: child, live: status == .running, now: now))
        }
        return CrewFanout(host: host, children: children)
    }

    private static func node(
        id: String, title: String, run: String, status: RunStatus, steps: [StreamStep],
        seconds: Double?
    ) -> Node {
        let state: Node.State
        var outcome: String?
        switch status {
        case .running: state = .running
        case .finished(let word, let summary):
            state = word == "completed" ? .completed : .failed
            outcome = summary.isEmpty ? word : summary
        case .failed(let reason):
            state = .failed
            outcome = reason
        }
        let shown = steps.filter {
            if case .delegated = $0.kind { return false }
            return true
        }
        let step = shown.last.map { "step \(shown.count) · \(CrewFanoutText.step($0.kind))" }
        return Node(
            id: id, title: title, run: run, state: state, step: step, seconds: seconds,
            outcome: outcome)
    }

    /// From the run's first event to its last, or to now while it runs.
    private static func seconds(
        events: [FeatureEvent], run: String, live: Bool, now: Date
    ) -> Double? {
        let times = events.filter { $0.run == run }.map(\.at)
        guard let first = times.min() else { return nil }
        return (live ? now : times.max() ?? first).timeIntervalSince(first)
    }
}

enum CrewFanoutText {
    /// A step in a few words: "tool search…", "decided billing", "proposed label".
    static func step(_ kind: StreamStep.Kind) -> String {
        switch kind {
        case .started: return "started"
        case .message(let role, _): return role == "user" ? "read the message" : "wrote a reply"
        case .thinking: return "thinking"
        case .status(let state, let detail): return detail.isEmpty ? state : detail
        case .error(let message): return "error: \(message)"
        case .toolCall(let call): return "tool \(call.tool)" + (call.output == nil ? "…" : "")
        case .decision(_, let choice, _, _): return "decided \(choice)"
        case .action(let action): return "proposed \(action.kind)"
        case .finished(let status, _): return status
        case .failed: return "failed"
        case .delegated(let delegation): return "delegated \(delegation.title)"
        }
    }

    /// "4.2 s", "1m 05s".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds)
        return String(format: "%dm %02ds", whole / 60, whole % 60)
    }

    /// "2 running · 1 done · 1 refused or failed".
    static func tally(_ fanout: CrewFanout) -> String {
        let (running, done, failed) = fanout.tally
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed or refused") }
        return parts.joined(separator: " · ")
    }
}
