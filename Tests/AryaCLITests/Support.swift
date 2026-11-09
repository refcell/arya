import Foundation

@testable import AryaCLI

/// Captures what a command writes to stdout and stderr.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var outLines: [String] = []
    private var errLines: [String] = []

    var out: [String] { lock.withLock { outLines } }
    var err: [String] { lock.withLock { errLines } }
    var outText: String { out.joined(separator: "\n") }
    var errText: String { err.joined(separator: "\n") }

    var output: Output {
        Output(
            write: { line in self.lock.withLock { self.outLines.append(line) } },
            writeError: { line in self.lock.withLock { self.errLines.append(line) } })
    }
}

/// An in-memory backend with canned data that records the calls it receives.
final class FakeBackend: CLIBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var verifyResult = VerifyReport(isValid: true, events: 3, firstBreak: nil)
    var runStatus = "completed"
    var replayDiverges = false

    var calls: [String] { lock.withLock { log } }
    func record(_ call: String) { lock.withLock { log.append(call) } }

    static let summary = StewardRow(
        id: "st_triage", name: "Support inbox triage", state: .draft, charterVersion: 1,
        pendingApprovals: 1, lastRun: nil)
    static let detail = StewardDetail(
        summary: summary, outcome: "Every message is routed within one hour.",
        metric: "routed_within_1h (ratio, up, target 0.95)",
        guardrails: ["Never delete a message."], bindings: ["inbox", "person:alex"],
        triggers: ["manual", "every 900s"], adapter: "fake", effort: "medium")
    static let approval = ApprovalRow(
        id: "ap_1", steward: "st_triage", run: "run_1", action: "reply", target: "inbox:MSG-1",
        rationale: "customer asked a known question", state: .pending,
        requestedAt: "2026-01-01T12:00:00.000Z")

    func initHome() async throws(CLIError) -> InitReport {
        record("init")
        return InitReport(home: "/tmp/home", status: .created)
    }
    func createSteward(charterPath: String) async throws(CLIError) -> StewardDetail {
        record("create \(charterPath)")
        return Self.detail
    }
    func listStewards() async throws(CLIError) -> [StewardRow] {
        record("list")
        return [Self.summary]
    }
    func showSteward(_ id: String) async throws(CLIError) -> StewardDetail {
        record("show \(id)")
        guard id == "st_triage" else { throw .notFound("steward \(id)") }
        return Self.detail
    }
    func startRun(steward: String, input: String?) async throws(CLIError) -> RunReport {
        record("run \(steward) \(input ?? "-")")
        return RunReport(
            run: "run_1", steward: steward, status: runStatus, summary: "routed one message",
            decisions: ["billing"],
            actions: [
                ActionOutcome(
                    id: "a1", kind: "label", target: "inbox:MSG-1", disposition: .executed,
                    approval: nil),
                ActionOutcome(
                    id: "a2", kind: "reply", target: "inbox:MSG-1", disposition: .held,
                    approval: "ap_1"),
            ])
    }
    func showRun(_ id: String) async throws(CLIError) -> RunReport {
        record("show run \(id)")
        return try await startRun(steward: "st_triage", input: nil)
    }
    func listApprovals(steward: String?, scope: ApprovalScope) async throws(CLIError)
        -> [ApprovalRow]
    {
        record("approvals \(steward ?? "-") \(scope)")
        return [Self.approval]
    }
    func decide(approval: String, decision: ApprovalDecision, note: String?)
        async throws(CLIError) -> ApprovalRow
    {
        record("decide \(approval) \(decision.rawValue) \(note ?? "-")")
        let a = Self.approval
        return ApprovalRow(
            id: approval, steward: a.steward, run: a.run, action: a.action, target: a.target,
            rationale: a.rationale, state: decision == .grant ? .granted : .denied,
            requestedAt: a.requestedAt)
    }
    func tailLedger(count: Int, steward: String?) async throws(CLIError) -> [EventSummary] {
        record("tail \(count) \(steward ?? "-")")
        return [
            EventSummary(
                seq: 1, at: "2026-01-01T12:00:00.000Z", type: "steward.created",
                actor: "human:local", steward: "st_triage", run: nil)
        ]
    }
    func verifyLedger() async throws(CLIError) -> VerifyReport {
        record("verify")
        return verifyResult
    }
}

/// A fixed context: no environment, a fake user home, a fake working directory.
let testContext = CLI.Context(
    environment: [:], userHome: URL(fileURLWithPath: "/home-test", isDirectory: true),
    workingDirectory: URL(fileURLWithPath: "/work", isDirectory: true))

/// Runs the CLI against `backend` and returns the exit status and captured output.
func runCLI(
    _ arguments: [String], backend: FakeBackend = FakeBackend(), context: CLI.Context = testContext
) async -> (status: ExitStatus, capture: Capture) {
    let capture = Capture()
    let status = await CLI.run(
        arguments, context: context, output: capture.output, backend: { _ in backend })
    return (status, capture)
}

extension FakeBackend {
    static let casebook = CasebookRow(
        name: "casebook", steward: "st_triage", version: String(repeating: "ab", count: 32),
        cases: 8)

    func importCasebook(steward: String, path: String, name: String?) async throws(CLIError)
        -> CasebookRow
    {
        record("import \(steward) \(path) \(name ?? "-")")
        return Self.casebook
    }
    func listCasebooks(steward: String?) async throws(CLIError) -> [CasebookRow] {
        record("casebooks \(steward ?? "-")")
        return [Self.casebook]
    }
    func rehearse(steward: String, casebook: String?) async throws(CLIError) -> RehearsalReport {
        record("rehearse \(steward) \(casebook ?? "-")")
        let cases = (1...8).map { n in
            RehearsedCase(id: "case-000\(n)", passed: n != 6, score: n == 6 ? 0 : 1, leak: false)
        }
        return RehearsalReport(
            rehearsal: "reh_1", steward: steward, casebook: "casebook", passed: 7, total: 8,
            score: 0.875, failed: ["case-0006"], cases: cases)
    }
    func correct(steward: String, case: String, choice: String?, note: String?)
        async throws(CLIError) -> CorrectionReport
    {
        record("correct \(steward) \(`case`) \(choice ?? "-") \(note ?? "-")")
        return CorrectionReport(
            steward: steward, case: `case`, choice: choice, note: note, memory: "mem_1")
    }
    func markReady(steward: String) async throws(CLIError) -> StewardDetail {
        record("ready \(steward)")
        return Self.detail
    }
    func propose(steward: String, charterPath: String) async throws(CLIError) -> ProposalRow {
        record("propose \(steward) \(charterPath)")
        return ProposalRow(
            id: "prop_1", steward: steward, kind: "charter", state: .passed, baseline: 0.875,
            candidate: 1, regressions: [])
    }
    func listProposals(steward: String?) async throws(CLIError) -> [ProposalRow] {
        record("proposals \(steward ?? "-")")
        return []
    }
    func metrics(steward: String, metric: String?) async throws(CLIError) -> [MetricSeries] {
        record("metrics \(steward) \(metric ?? "-")")
        return [
            MetricSeries(
                metric: "routed_within_1h", unit: "ratio", target: 0.95,
                points: [MetricPoint(at: "2026-01-01T12:00:00.000Z", value: 1)])
        ]
    }
    func memory(steward: String, scope: MemoryScope) async throws(CLIError) -> [MemoryRow] {
        record("memory \(steward) \(scope)")
        return [
            MemoryRow(
                id: "mem_1", text: "Card changes are billing.", tags: ["billing"],
                author: "human:local", run: nil, retracted: false)
        ]
    }
    func routines(steward: String) async throws(CLIError) -> [RoutineRow] {
        record("routines \(steward)")
        return []
    }
    func replay(run: String) async throws(CLIError) -> ReplayReport {
        record("replay \(run)")
        let divergences =
            replayDiverges
            ? [
                Divergence(
                    seq: 7, type: "run.decision", field: "payload.choice", recorded: "\"billing\"",
                    replayed: "\"bug\"")
            ] : []
        return ReplayReport(run: run, events: 12, divergences: divergences)
    }
    func serveBindingProxy(run: String, binding: String) async throws(CLIError) {
        record("proxy \(run) \(binding)")
    }
}
