import Arya
import Foundation
import Testing

@testable import AryaCLI

/// A fresh temporary directory, removed when `body` returns.
private func withTemporaryHome(_ body: (URL) async throws -> Void) async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-cli-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try await body(home)
}

@Test func initCreatesTheHomeThenReportsItExists() async throws {
    try await withTemporaryHome { home in
        let backend = WorkspaceBackend(home: home)
        let first = try await backend.initHome()
        #expect(first == InitReport(home: home.path, status: .created))
        var isDirectory: ObjCBool = false
        let ledger = home.appendingPathComponent("ledger").path
        #expect(FileManager.default.fileExists(atPath: ledger, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let second = try await backend.initHome()
        #expect(second == InitReport(home: home.path, status: .existing))
    }
}

@Test func missingCharterFileIsNotFound() async throws {
    try await withTemporaryHome { home in
        let backend = WorkspaceBackend(home: home)
        let path = home.appendingPathComponent("absent.json").path
        await #expect(throws: CLIError.notFound("charter file \(path)")) {
            try await backend.createSteward(charterPath: path)
        }
    }
}

@Test func unlandedFacadeCallsAreReportedAsUnavailable() async throws {
    try await withTemporaryHome { home in
        let capture = Capture()
        let status = await CLI.run(
            ["--home", home.path, "ledger", "verify"], context: testContext,
            output: capture.output, backend: { WorkspaceBackend(home: $0) })
        // Exit 69 until the facade call lands; then it must succeed on an empty ledger.
        if status == .unavailable {
            #expect(capture.errText.contains("Workspace.verifyLedger"))
        } else {
            #expect(status == .ok)
        }
    }
}

private let at = Date(timeIntervalSince1970: 1_767_268_800.123)  // 2026-01-01T12:00:00.123Z

private func entry(_ seq: Int, _ type: String, _ payload: String) -> LedgerEntry {
    LedgerEntry(
        seq: seq, id: "ev_\(seq)", at: at, type: type, steward: "st_triage", run: "run_1",
        actorKind: "steward", actorID: "st_triage", payload: payload)
}

@Test func timestampsAreRFC3339WithMilliseconds() {
    #expect(Mapping.timestamp(at) == "2026-01-01T12:00:00.123Z")
    #expect(Mapping.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
}

@Test func stewardStateCombinesStatusAndReadiness() {
    func state(_ status: StewardSummary.Status, ready: Bool) -> StewardState {
        let steward = StewardSummary(
            id: "st_a", name: "A", outcome: "o", charterVersion: 2, status: status, ready: ready)
        return Mapping.steward(steward, pendingApprovals: 0, lastRun: nil).state
    }
    #expect(state(.active, ready: false) == .draft)
    #expect(state(.active, ready: true) == .ready)
    #expect(state(.paused, ready: true) == .paused)
    #expect(state(.retired, ready: true) == .retired)
}

@Test func runReportReadsDecisionsAndDispositions() {
    let entries = [
        entry(1, "run.started", #"{"trigger":{"kind":"manual"}}"#),
        entry(2, "run.decision", #"{"decision":{"id":"d1","choice":"billing"}}"#),
        entry(11, "run.decision", #"{"id":"d2","choice":"refund"}"#),
        entry(3, "action.proposed", #"{"id":"a1","kind":"label","target":"inbox:MSG-201"}"#),
        entry(
            4, "action.proposed", #"{"action":{"id":"a2","kind":"route","target":"inbox:MSG-201"}}"#
        ),
        entry(5, "action.proposed", #"{"id":"a3","kind":"reply","target":"inbox:MSG-201"}"#),
        entry(6, "action.proposed", #"{"id":"a4","kind":"delete","target":"inbox:MSG-201"}"#),
        entry(7, "action.executed", #"{"action":"a1","output":"ok"}"#),
        entry(8, "action.executed", #"{"action":{"id":"a2"}}"#),
        entry(
            9, "approval.requested", #"{"approval":"ap_1","kind":"action","action":{"id":"a3"}}"#),
        entry(10, "action.rejected", #"{"action":"a4","rule":"deny"}"#),
    ]
    let run = RunSummary(
        id: "run_1", steward: "st_triage", trigger: "manual", charterVersion: 1,
        status: .finished, endStatus: "completed", summary: "routed", startedAt: at)
    let report = Mapping.report(run, entries: entries.reversed(), approvals: [])
    #expect(report.status == "completed")
    #expect(report.decisions == ["billing", "refund"])
    #expect(report.actions.map(\.disposition) == [.executed, .executed, .held, .rejected])
    #expect(report.actions.map(\.approval) == [nil, nil, "ap_1", nil])
}

@Test func heldActionsFallBackToTheApprovalQueue() {
    let entries = [entry(1, "action.proposed", #"{"id":"a3","kind":"reply","target":"inbox:M"}"#)]
    let approval = ApprovalSummary(
        id: "ap_9", kind: .action, steward: "st_triage", run: "run_1", actionKind: "reply",
        target: "inbox:M", text: "why", status: .pending, requestedAt: at)
    let digest = RunDigest(entries: entries, approvals: [approval])
    #expect(digest.actions.first?.disposition == .held)
    #expect(digest.actions.first?.approval == "ap_9")
    #expect(RunDigest(entries: entries, approvals: []).actions.first?.disposition == .proposed)
}

@Test func failedRunsReportTheirReason() {
    let run = RunSummary(
        id: "run_2", steward: "st_triage", trigger: "manual", charterVersion: 1, status: .failed,
        failureReason: "adapter_exited", startedAt: at)
    let report = Mapping.report(run, entries: [], approvals: [])
    #expect(report.status == "failed")
    #expect(report.summary == "failed: adapter_exited")
}

@Test func charterDigestRendersTheExampleCharter() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("etc/examples/triage/charter.json")
    let digest = try #require(CharterDigest(json: Data(contentsOf: url)))
    #expect(digest.metric == "routed_within_1h (ratio, up, target 0.95)")
    #expect(digest.bindings == ["inbox", "billing", "person:sam"])
    #expect(digest.triggers == ["every 900s", "manual"])
    #expect(digest.adapter == "fake-triage")
    #expect(digest.effort == "medium")
    #expect(CharterDigest(json: Data("[]".utf8)) == nil)
}

@Test func approvalsAndVerifyMapToRows() {
    let approval = ApprovalSummary(
        id: "ap_1", kind: .question, steward: "st_triage", run: "run_1", text: "Which queue?",
        status: .granted, requestedAt: at)
    let row = Mapping.approval(approval)
    #expect(row.action == "question")
    #expect(row.target == "-")
    #expect(row.state == .granted)
    #expect(row.requestedAt == "2026-01-01T12:00:00.123Z")
    let broken = Mapping.verify(LedgerCheck(ok: false, events: 5, firstBadSeq: 3, detail: "gap"))
    #expect(broken.firstBreak == VerifyReport.Break(seq: 3, reason: "gap"))
    #expect(Mapping.verify(LedgerCheck(ok: true, events: 5)).firstBreak == nil)
}

/// Decodes a facade read model; dates are seconds since 2001 (Foundation's default).
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Test func metricSeriesPutTheCharterMetricFirst() throws {
    let summary = try decode(
        MetricSeriesSummary.self,
        """
        {"steward":"st_triage","metric":"routed_within_1h","unit":"ratio","direction":"up",
         "target":0.95,"windowSeconds":86400,"windows":[
          {"start":0,"means":{"routed_within_1h":1,"latency":3},"counts":{},"executed":2,
           "failed":0,"rejected":0,"granted":1,"denied":0,"expired":0},
          {"start":86400,"means":{},"counts":{},"executed":0,"failed":0,"rejected":0,
           "granted":0,"denied":0,"expired":0}]}
        """)
    let series = Mapping.series(summary)
    #expect(series.map(\.metric) == ["routed_within_1h", "latency"])
    #expect(series[0].points == [MetricPoint(at: "2001-01-01T00:00:00.000Z", value: 1)])
    #expect(series[0].unit == "ratio")
    #expect(series[0].target == 0.95)
    #expect(series[1].unit == nil)
}

@Test func runDetailBecomesARunReport() throws {
    let detail = try decode(
        RunDetail.self,
        """
        {"run":{"id":"run_1","steward":"st_triage","trigger":"manual","charterVersion":1,
                "status":"finished","endStatus":"completed","summary":"routed",
                "startedAt":0,"costMicros":0,"actionsProposed":2},
         "input":"hello","decisions":[{"id":"d1","choice":"billing"}],
         "actions":[
          {"id":"a1","kind":"label","target":"inbox:M","policy":"auto","policyReason":"rule",
           "disposition":"executed","approval":"ap_x"},
          {"id":"a2","kind":"reply","policy":"ask","policyReason":"rule",
           "disposition":"held","approval":"ap_1"}]}
        """)
    let report = Mapping.report(detail)
    #expect(report.decisions == ["billing"])
    #expect(report.actions.map(\.disposition) == [.executed, .held])
    #expect(report.actions.map(\.approval) == [nil, "ap_1"])
    #expect(report.actions[1].target == "-")
    #expect(report.summary == "routed")
}

@Test func runShowParsesAndRenders() async {
    let backend = FakeBackend()
    let (status, capture) = await runCLI(["run", "show", "run_1"], backend: backend)
    #expect(status == .ok)
    #expect(backend.calls.first == "show run run_1")
    #expect(capture.out.first == "run run_1 (st_triage) completed")
}

@Test func replaySummaryMapsDivergences() throws {
    let summary = try decode(
        ReplaySummary.self,
        """
        {"run":"run_1","events":12,"divergences":[
          {"index":3,"seq":7,"type":"run.decision","field":"payload.choice",
           "recorded":"\\"billing\\"","replayed":"\\"bug\\""},
          {"index":9,"type":"run.finished","field":"payload.status",
           "recorded":"completed","replayed":"failed"}]}
        """)
    let report = Mapping.replay(summary)
    #expect(report.events == 12)
    #expect(report.divergences.map(\.seq) == [7, 9])
    #expect(report.divergences[0].replayed == "\"bug\"")
}

@Test func proposalsMapStatusAndVerdict() throws {
    let open = try decode(
        ProposalSummary.self,
        """
        {"id":"pr_1","steward":"st_triage","baseVersion":1,"candidateVersion":2,
         "author":"human:local","status":"open","acceptable":false}
        """)
    let failed = try decode(
        ProposalSummary.self,
        """
        {"id":"pr_2","steward":"st_triage","baseVersion":1,"candidateVersion":2,
         "author":"human:local","status":"failed","acceptable":false,
         "verdict":{"passed":false,"baselineMean":0.9,"candidateMean":0.7,
                    "regressions":["case-0003"],"reason":"regressed"}}
        """)
    #expect(Mapping.proposal(open).state == .rehearsing)
    #expect(Mapping.proposal(open).regressions.isEmpty)
    let row = Mapping.proposal(failed)
    #expect(row.state == .failed)
    #expect(row.baseline == 0.9)
    #expect(row.candidate == 0.7)
    #expect(row.regressions == ["case-0003"])
}
