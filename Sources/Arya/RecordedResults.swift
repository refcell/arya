import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
import Foundation

/// The `run/result` each run recorded on the ledger (in its `run.adapter.event` wire records),
/// typed. It carries what the runtime does not fold into its own events yet: the plan, action
/// risk hints, and the one-line `why` on decisions and actions.
struct RecordedResults {
    /// Results by run id, and the `seq` of the event that carried each.
    private(set) var results: [RunID: (seq: Int, at: Date, result: RunResult)] = [:]

    init(_ events: some Sequence<Event>) {
        for event in events where event.type.rawValue == RunEventType.adapterEvent {
            guard let run = event.run,
                let record = WireRecord(ledgerPayload: event.payload),
                case .notification(let notification)? = record.message,
                notification.method == RPCMethod.runResult,
                let raw = notification.params,
                let params = try? CanonicalJSON.decode(
                    RunResultParams.self, from: try CanonicalJSON.encode(raw)),
                let result = try? params.decodedResult()
            else { continue }
            results[run] = (Int(event.seq), event.at.date, result)
        }
    }

    /// The newest recorded result with a plan among `runs`.
    func latestPlan(among runs: Set<RunID>) -> (run: RunID, at: Date, result: RunResult)? {
        results.filter { runs.contains($0.key) && !$0.value.result.plan.isEmpty }
            .max { $0.value.seq < $1.value.seq }
            .map { ($0.key, $0.value.at, $0.value.result) }
    }

    /// The recorded form of one action of a run.
    func action(_ id: String, run: RunID) -> RunResult.Action? {
        results[run]?.result.actions.first { $0.id == id }
    }

    /// The recorded form of one decision of a run.
    func decision(_ id: String, run: RunID) -> RunResult.Decision? {
        results[run]?.result.decisions.first { $0.id == id }
    }
}
