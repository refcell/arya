import AryaCore
import AryaLedger
import AryaRuntime

/// A run and its crew as one unit: the parent, its children by delegation id, then the join
/// run. Live readiness and What if count and compare a crew once, on the whole tree's effect.
enum CrewTree {
    /// `run` followed by its crew children and join run; just `run` when it did not delegate.
    static func members(_ events: [RuntimeEvent], of run: RunID) throws -> [RunID] {
        // Children by delegation id, however they were started (result delegations or an
        // in-run host/delegate), so parallel crews compare in a stable order.
        var children: [(delegation: String, run: RunID)] = []
        var join: RunID?
        for event in events {
            if event.type == RunDelegated.type.rawValue, event.draft.run == run {
                let body = try EvalPayload.decode(RunDelegated.self, event.payload)
                if let child = body.child { children.append((body.delegation, child)) }
            } else if event.type == RunEventType.started, let member = event.draft.run {
                let body = try EvalPayload.decode(RunStarted.self, event.payload)
                if body.parent == run, body.input.kind == .join { join = member }
            }
        }
        let ordered = children.sorted { $0.delegation < $1.delegation }.map(\.run)
        return [run] + ordered + (join.map { [$0] } ?? [])
    }

    /// True for a crew child or join run (`run.started` names a parent).
    static func isMember(_ started: RunStarted) -> Bool { started.parent != nil }

    /// What the whole tree did: every member's decisions, then every member's actions, in
    /// member order, in the shape of a case's expected result.
    static func did(_ events: [RuntimeEvent], runs: [RunID]) throws -> JSONValue {
        var decisions: [JSONValue] = []
        var actions: [JSONValue] = []
        for run in runs {
            let did = try RunCases.did(events, run: run)
            decisions += did["decisions"]?.arrayValue ?? []
            actions += did["actions"]?.arrayValue ?? []
        }
        return ["decisions": .array(decisions), "actions": .array(actions)]
    }

    /// Every member's recorded tool results, without repeats, so rehearsal serves the whole
    /// crew's reads.
    static func recordings(_ events: [RuntimeEvent], runs: [RunID]) throws
        -> [RecordedToolResult]
    {
        var seen: [RecordedToolResult] = []
        for run in runs {
            for item in try RunRecordings.from(events, run: run) where !seen.contains(item) {
                seen.append(item)
            }
        }
        return seen
    }
}
