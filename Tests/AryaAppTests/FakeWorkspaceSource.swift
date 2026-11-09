import Arya
import Foundation

@testable import AryaApp

/// An in-memory `WorkspaceSource` with invented stewards, runs, and approvals: the shell's test
/// double. Its `st_triage` run ids match the feature views' `PreviewFixtures`. The app itself
/// has no preview mode; `just demo` seeds a real home instead.
/// Writes append ledger entries and wake every event stream, like the real facade.
actor FakeWorkspaceSource: WorkspaceSource {
    nonisolated let label = "Preview"
    private var stewardList: [StewardSummary]
    private var runList: [RunSummary]
    private var approvalList: [ApprovalSummary]
    private var effortMap: [String: String]
    private var entries: [LedgerEntry] = []
    private var watchers: [UUID: AsyncThrowingStream<LedgerEntry, Error>.Continuation] = [:]
    private let now: Date

    /// - Parameter now: the fixed "current" time sample data is placed around.
    init(now: Date = FakeWorkspaceSource.referenceDate, empty: Bool = false) {
        self.now = now
        let sample = empty ? FakeWorkspaceData.empty : FakeWorkspaceData.sample(now: now)
        stewardList = sample.stewards
        runList = sample.runs
        approvalList = sample.approvals
        effortMap = sample.efforts
        var entries: [LedgerEntry] = []
        for (type, steward) in sample.history {
            entries.append(
                Self.entry(seq: entries.count + 1, type: type, steward: steward, run: nil, now: now)
            )
        }
        self.entries = entries
    }

    /// 9 Nov 2026, 14:02 UTC: a fixed clock so previews and tests never read the wall clock.
    static let referenceDate = Date(timeIntervalSince1970: 1_794_232_920)

    func stewards() -> [StewardSummary] { stewardList.sorted { $0.id < $1.id } }

    func runs(steward: String?) -> [RunSummary] {
        runList.filter { steward == nil || $0.steward == steward }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func approvals(includeDecided: Bool) -> [ApprovalSummary] {
        approvalList.filter { includeDecided || $0.status == .pending }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    func approve(_ id: String, note: String?) throws -> ApprovalSummary {
        try decide(id, status: .granted, type: "approval.granted")
    }

    func deny(_ id: String, note: String?) throws -> ApprovalSummary {
        try decide(id, status: .denied, type: "approval.denied")
    }

    func ledger(from seq: Int, limit: Int?) -> [LedgerEntry] {
        let tail = entries.filter { $0.seq >= seq }
        return limit.map { Array(tail.prefix($0)) } ?? tail
    }

    nonisolated func events(from seq: Int) -> AsyncThrowingStream<LedgerEntry, Error> {
        let (stream, continuation) = AsyncThrowingStream<LedgerEntry, Error>.makeStream()
        let key = UUID()
        Task { await self.watch(key, continuation, from: seq) }
        continuation.onTermination = { _ in Task { await self.unwatch(key) } }
        return stream
    }

    func verifyLedger() -> LedgerCheck { LedgerCheck(ok: true, events: entries.count) }

    func efforts() -> [String: String] { effortMap }

    func setEffort(_ effort: String, steward: String) throws {
        guard stewardList.contains(where: { $0.id == steward }) else {
            throw WorkspaceError.notFound(steward)
        }
        effortMap[steward] = effort
        record("steward.charter.updated", steward: steward, run: nil)
    }

    /// Appends a run and its `run.started` event, as a trigger would. For tests and demos.
    func startRun(_ run: RunSummary) {
        runList.append(run)
        record("run.started", steward: run.steward, run: run.id)
    }

    func pauseSteward(_ id: String) throws {
        try setStatus(.paused, of: id, type: "steward.paused")
    }

    func resumeSteward(_ id: String) throws {
        try setStatus(.active, of: id, type: "steward.resumed")
    }

    func startRun(steward: String, input: String) throws -> RunSummary {
        guard stewardList.contains(where: { $0.id == steward }) else {
            throw WorkspaceError.notFound(steward)
        }
        let run = RunSummary(
            id: "run_\(runList.count + 100)", steward: steward, trigger: "manual",
            charterVersion: 1, status: .finished, summary: input,
            startedAt: now.addingTimeInterval(Double(entries.count)))
        startRun(run)
        return run
    }

    private func setStatus(_ status: StewardSummary.Status, of id: String, type: String) throws {
        guard let index = stewardList.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.notFound(id)
        }
        stewardList[index].status = status
        record(type, steward: id, run: nil)
    }

    /// Appends a pending approval and its `approval.requested` event. For tests and demos.
    func requestApproval(_ approval: ApprovalSummary) {
        approvalList.append(approval)
        record("approval.requested", steward: approval.steward, run: approval.run)
    }

    private func decide(
        _ id: String, status: ApprovalSummary.Status, type: String
    ) throws -> ApprovalSummary {
        guard let index = approvalList.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.notFound(id)
        }
        guard approvalList[index].status == .pending else {
            throw WorkspaceError.rejected("\(id) was already decided")
        }
        approvalList[index].status = status
        approvalList[index].decidedBy = "local"
        let approval = approvalList[index]
        record(type, steward: approval.steward, run: approval.run)
        return approval
    }

    private func record(_ type: String, steward: String?, run: String?) {
        let entry = Self.entry(
            seq: entries.count + 1, type: type, steward: steward, run: run, now: now)
        entries.append(entry)
        for watcher in watchers.values { watcher.yield(entry) }
    }

    private static func entry(
        seq: Int, type: String, steward: String?, run: String?, now: Date
    ) -> LedgerEntry {
        LedgerEntry(
            seq: seq, id: "evt_\(seq)", at: now.addingTimeInterval(Double(seq)), type: type,
            steward: steward, run: run, actorKind: "human", actorID: "local", payload: "{}")
    }

    private func watch(
        _ key: UUID, _ continuation: AsyncThrowingStream<LedgerEntry, Error>.Continuation,
        from seq: Int
    ) {
        for entry in entries where entry.seq >= seq { continuation.yield(entry) }
        watchers[key] = continuation
    }

    private func unwatch(_ key: UUID) { watchers[key] = nil }
}

/// Sample stewards, runs, and approvals. Every name is invented.
enum FakeWorkspaceData {
    struct Sample {
        var stewards: [StewardSummary] = []
        var runs: [RunSummary] = []
        var approvals: [ApprovalSummary] = []
        var efforts: [String: String] = [:]
        var history: [(String, String?)] = []
    }

    static let empty = Sample()

    static func sample(now: Date) -> Sample {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let stewards = [
            StewardSummary(
                id: "st_triage", name: "Triage keeper",
                outcome: "Keep the issue queue sorted and answered", charterVersion: 3,
                status: .active, ready: true),
            StewardSummary(
                id: "st_spend", name: "Spend watcher",
                outcome: "Keep monthly compute spend under budget", charterVersion: 1,
                status: .active, ready: false),
            StewardSummary(
                id: "st_digest", name: "Release digest",
                outcome: "Publish a readable weekly release digest", charterVersion: 2,
                status: .paused, ready: true),
        ]
        let runs = [
            run("run_0002", "st_triage", .running, started: ago(2)),
            run(
                "run_0001", "st_triage", .finished, started: ago(65),
                summary: "Closed 3 duplicates"),
            run("run_0000", "st_triage", .failed, started: ago(190), failure: "timeout"),
            run("run_7", "st_spend", .finished, started: ago(300), summary: "No anomalies"),
        ]
        let approvals = [
            ApprovalSummary(
                id: "ap_1", kind: .action, steward: "st_triage", run: "run_0002",
                actionKind: "close_issue", binding: "tracker", target: "tracker:ISSUE-418",
                text: "It repeats ISSUE-411 word for word.", status: .pending,
                requestedAt: ago(1)),
            ApprovalSummary(
                id: "ap_2", kind: .question, steward: "st_spend", run: "run_7",
                text: "Should the nightly batch move to the cheaper tier?", status: .pending,
                requestedAt: ago(240)),
        ]
        return Sample(
            stewards: stewards, runs: runs, approvals: approvals,
            efforts: ["st_triage": "medium", "st_spend": "low", "st_digest": "high"],
            history: stewards.map { ("steward.created", $0.id) })
    }

    private static func run(
        _ id: String, _ steward: String, _ status: RunSummary.Status, started: Date,
        summary: String? = nil, failure: String? = nil
    ) -> RunSummary {
        RunSummary(
            id: id, steward: steward, trigger: "manual", charterVersion: 1, status: status,
            failureReason: failure, summary: summary, startedAt: started,
            endedAt: status == .running ? nil : started.addingTimeInterval(90))
    }
}
