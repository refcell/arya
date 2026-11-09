import Arya
import Foundation

/// What the app reads and writes through the facade. `Workspace` conforms; `PreviewWorkspace`
/// is an in-memory stand-in for development, screenshots, and tests.
protocol WorkspaceSource: Sendable {
    /// A short label for the window subtitle: the home's folder name or "Preview".
    var label: String { get }
    func stewards() async throws -> [StewardSummary]
    func runs(steward: String?) async throws -> [RunSummary]
    func approvals(includeDecided: Bool) async throws -> [ApprovalSummary]
    func approve(_ id: String, note: String?) async throws -> ApprovalSummary
    func deny(_ id: String, note: String?) async throws -> ApprovalSummary
    func ledger(from seq: Int, limit: Int?) async throws -> [LedgerEntry]
    func events(from seq: Int) -> AsyncThrowingStream<LedgerEntry, Error>
    func verifyLedger() async throws -> LedgerCheck
    /// Each steward's charter effort (`low`, `medium`, `high`) by steward id.
    func efforts() async throws -> [String: String]
    /// Changes a steward's charter effort.
    func setEffort(_ effort: String, steward: String) async throws
}

extension Workspace: WorkspaceSource {
    nonisolated var label: String { home.lastPathComponent }

    func efforts() async throws -> [String: String] {
        // The facade has no effort read yet; every steward shows the charter default.
        [:]
    }

    func setEffort(_ effort: String, steward: String) async throws {
        throw WorkspaceError.unavailable("setEffort")
    }
}
