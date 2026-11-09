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
        case .unavailable: throw .unavailable("Workspace.\(name) (runtime lane)")
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
