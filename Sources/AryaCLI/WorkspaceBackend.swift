import Arya
import Foundation

/// The backend over `Arya.Workspace`. Facade calls that have not landed yet throw
/// `WorkspaceError.unavailable`, which becomes "not available yet" (exit 69) naming the call.
struct WorkspaceBackend: CLIBackend {
    let home: URL

    private func open() async throws(CLIError) -> Workspace {
        try await call("open") { try await Workspace.open(home: home) }
    }

    func initHome() async throws(CLIError) -> InitReport {
        let ledger = home.appendingPathComponent("ledger", isDirectory: true)
        let existed = FileManager.default.fileExists(atPath: ledger.path)
        _ = try await open()
        return InitReport(home: home.path, status: existed ? .existing : .created)
    }

    func createSteward(charterPath: String) async throws(CLIError) -> StewardDetail {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: charterPath))
        } catch {
            throw .notFound("charter file \(charterPath)")
        }
        let workspace = try await open()
        let summary = try await call("createSteward", rejection: { .invalidInput($0) }) {
            try await workspace.createSteward(charter: data)
        }
        return Mapping.detail(
            Mapping.steward(summary, pendingApprovals: 0, lastRun: nil),
            outcome: summary.outcome, charter: CharterDigest(json: data))
    }

    func listStewards() async throws(CLIError) -> [StewardRow] {
        let workspace = try await open()
        let stewards = try await call("stewards") { try await workspace.stewards() }
        let approvals = await optional { try await workspace.approvals() } ?? []
        let runs = await optional { try await workspace.runs() } ?? []
        return stewards.map { steward in
            Mapping.steward(
                steward, pendingApprovals: approvals.filter { $0.steward == steward.id }.count,
                lastRun: runs.first { $0.steward == steward.id }?.id)
        }
    }

    func showSteward(_ id: String) async throws(CLIError) -> StewardDetail {
        let workspace = try await open()
        guard let steward = try await call("steward", { try await workspace.steward(id) }) else {
            throw .notFound("steward \(id)")
        }
        let approvals = await optional { try await workspace.approvals() } ?? []
        let runs = await optional { try await workspace.runs(steward: id) } ?? []
        let summary = Mapping.steward(
            steward, pendingApprovals: approvals.filter { $0.steward == id }.count,
            lastRun: runs.first?.id)
        return Mapping.detail(summary, outcome: steward.outcome, charter: nil)
    }

    func startRun(steward: String, input: String?) async throws(CLIError) -> RunReport {
        let workspace = try await open()
        let run = try await call("startRun") {
            try await workspace.startRun(steward: steward, input: input ?? "")
        }
        let entries = await optional { try await workspace.ledger() } ?? []
        let approvals = await optional { try await workspace.approvals(includeDecided: true) } ?? []
        return Mapping.report(
            run, entries: entries.filter { $0.run == run.id },
            approvals: approvals.filter { $0.run == run.id })
    }

    func listApprovals(steward: String?, scope: ApprovalScope) async throws(CLIError)
        -> [ApprovalRow]
    {
        let workspace = try await open()
        let approvals = try await call("approvals") {
            try await workspace.approvals(includeDecided: scope == .all)
        }
        return approvals.filter { steward == nil || $0.steward == steward }.map(Mapping.approval)
    }

    func decide(approval: String, decision: ApprovalDecision, note: String?)
        async throws(CLIError) -> ApprovalRow
    {
        let workspace = try await open()
        let result =
            switch decision {
            case .grant:
                try await call("approve") { try await workspace.approve(approval, note: note) }
            case .deny: try await call("deny") { try await workspace.deny(approval, note: note) }
            }
        return Mapping.approval(result)
    }

    func tailLedger(count: Int, steward: String?) async throws(CLIError) -> [EventSummary] {
        let workspace = try await open()
        let entries = try await call("ledger") { try await workspace.ledger() }
        let matching = entries.filter { steward == nil || $0.steward == steward }
        return matching.suffix(count).map(Mapping.event)
    }

    func verifyLedger() async throws(CLIError) -> VerifyReport {
        let workspace = try await open()
        let check = try await call("verifyLedger") { try await workspace.verifyLedger() }
        return Mapping.verify(check)
    }
}

/// Runs a facade call, mapping its errors. `rejection` picks how `WorkspaceError.rejected` is
/// reported (an invalid charter is invalid input; an already-decided approval is a failure).
private func call<T>(
    _ name: String, rejection: (String) -> CLIError = { .failed($0) },
    _ body: () async throws -> T
) async throws(CLIError) -> T {
    do {
        return try await body()
    } catch let error as WorkspaceError {
        switch error {
        case .unavailable: throw .unavailable("Workspace.\(name) (workspace lane)")
        case .notFound(let id): throw .notFound(id)
        case .rejected(let detail): throw rejection(detail)
        }
    } catch {
        throw .failed("\(name): \(error)")
    }
}

/// A facade call whose result only enriches the output: `nil` when it fails.
private func optional<T>(_ body: () async throws -> T) async -> T? {
    try? await body()
}

// The improvement loop. The facade does not expose these calls yet (workspace lane, M2); each
// names the call it will use so `just e2e` reports exactly what is missing.
extension WorkspaceBackend {
    private func missing(_ call: String) -> CLIError {
        .unavailable("Workspace.\(call) (workspace lane)")
    }

    func importCasebook(steward: String, path: String, name: String?) async throws(CLIError)
        -> CasebookRow
    { throw missing("importCasebook") }
    func listCasebooks(steward: String?) async throws(CLIError) -> [CasebookRow] {
        throw missing("casebooks")
    }
    func rehearse(steward: String, casebook: String?) async throws(CLIError) -> RehearsalReport {
        throw missing("rehearse")
    }
    func correct(steward: String, case: String, choice: String?, note: String?)
        async throws(CLIError) -> CorrectionReport
    { throw missing("correct") }
    func markReady(steward: String) async throws(CLIError) -> StewardDetail {
        throw missing("markReady")
    }
    func propose(steward: String, charterPath: String) async throws(CLIError) -> ProposalRow {
        throw missing("propose")
    }
    func listProposals(steward: String?) async throws(CLIError) -> [ProposalRow] {
        throw missing("proposals")
    }
    func metrics(steward: String, metric: String?) async throws(CLIError) -> [MetricSeries] {
        throw missing("metrics")
    }
    func memory(steward: String, scope: MemoryScope) async throws(CLIError) -> [MemoryRow] {
        throw missing("memory")
    }
    func routines(steward: String) async throws(CLIError) -> [RoutineRow] {
        throw missing("routines")
    }
    func replay(run: String) async throws(CLIError) -> ReplayReport { throw missing("replay") }
    func serveBindingProxy(run: String, binding: String) async throws(CLIError) {
        throw missing("bindingProxy")
    }
}
