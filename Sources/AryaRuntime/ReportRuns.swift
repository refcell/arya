import AryaCore
import AryaLedger
import Foundation

// Report runs (decision 0050). A periodic report to people reached through a relay (an email or
// chat binding, decision 0042) is its own short run: `run.started` with input kind `report`
// and the digest as its text, one `send` action per person through the normal dispatcher, so
// policy, risk, autonomy, and approvals apply exactly as for any other action, and then
// `run.finished`. No adapter runs: the digest is computed by the caller from the ledger, never
// written by a model. Report runs never re-plan; a denied send is just a report not sent.

/// How a report run ended.
public struct ReportDelivery: Sendable, Hashable {
    /// The report run.
    public var run: RunID
    /// One disposal per person, in order.
    public var disposals: [ActionDisposal]
}

extension RunEngine {
    /// The action kind of a report send: the relay tool it calls.
    public static let reportKind = "send"

    /// Sends `text` (titled `subject`) to each of `steward`'s person bindings in `people` as a
    /// report run. People without a binding are skipped; with no one left nothing is recorded
    /// and the result is nil.
    public func report(
        _ text: String, subject: String, to people: [String], steward: StewardID,
        actor: RuntimeActor = .system
    ) async throws -> ReportDelivery? {
        let record = try await StewardLifecycle(sink: sink).book().records[steward]
        guard let record else { throw StewardError.notFound(steward) }
        guard record.status != .retired else { throw RunError.stewardRetired(steward) }
        let charter = record.charter
        let recipients = people.filter { charter.binding($0)?.kind == .person }
        guard !recipients.isEmpty else { return nil }
        let run = ambient.newID(RunID.self)
        let lease = try leases.acquire(run)
        defer { lease.release() }
        let started = RunStarted(
            input: RunInputRecord(kind: .report, text: text), charterVersion: record.version,
            adapter: charter.adapter, effort: charter.effort, instructions: "",
            limits: charter.limits)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: RunEventType.started, steward: steward, run: run, actor: actor,
                payload: try Payload.encode(started)))
        let actions = recipients.enumerated().map { index, person in
            ProposedAction(
                id: "r\(index + 1)", kind: Self.reportKind, binding: person,
                params: ["subject": .string(subject), "text": .string(text)],
                rationale: subject)
        }
        let disposals = try await dispatcher.dispose(actions, charter: charter, run: run)
        let finished = RunFinished(
            status: .completed, summary: "\(subject) to \(recipients.joined(separator: ", "))",
            counts: RunCounts(actions: actions.count))
        _ = try await sink.append(
            RuntimeEventDraft(
                type: RunEventType.finished, steward: steward, run: run, actor: .system,
                payload: try Payload.encode(finished)))
        return ReportDelivery(run: run, disposals: disposals)
    }
}
