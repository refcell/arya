import Arya
import Foundation
import Observation

// Governance in the app (ledger and governance lane): abort, undo, policy and approvers,
// retention, and encryption at rest, read and written through the facade. These files are
// governance-owned; the shell and views host them with one line each.

/// The governance calls the app makes. `Workspace` provides all of them.
protocol GovernanceSource: Sendable {
    func policySummary(steward: String) async throws -> PolicySummary
    func abortRun(_ id: String, reason: String?, as person: String) async throws -> RunSummary
    func undoOptions(run: String) async throws -> [UndoOption]
    func undoAction(run: String, action: String, reason: String?, as person: String)
        async throws -> UndoSummary
    func retention() async throws -> RetentionSummary
    func setRetention(steward: String?, days: Int?, as person: String) async throws
        -> RetentionSummary
    func applyRetention(as person: String) async throws -> RetentionSummary
    func importAudit(from directory: URL, as person: String) async throws -> AuditImportSummary
    func encryption() async throws -> EncryptionSummary
    func enableEncryption(as person: String) async throws -> EncryptionSummary
    func resealHistory(as person: String) async throws -> EncryptionSummary
    func exportAudit(steward: String?, to directory: URL, reveal: Bool, as person: String)
        async throws -> AuditExportSummary
}

extension Workspace: GovernanceSource {}

extension AppModel {
    /// The governance calls, when this home's source offers them.
    var governance: (any GovernanceSource)? { source as? any GovernanceSource }
}

extension FeatureStore {
    /// The governance calls behind this store's workspace, when it is the facade.
    var governance: (any GovernanceSource)? {
        (workspace as? FacadeFeatureWorkspace)?.source as? any GovernanceSource
    }
}

/// What the governance views show, loaded from the facade and kept between redraws so a view
/// draws at once (and offscreen snapshots draw loaded content). Refreshed on appear and after
/// every write.
@MainActor @Observable
final class GovernanceCache {
    static let shared = GovernanceCache()

    private(set) var policies: [String: PolicySummary] = [:]
    private(set) var undo: [String: [UndoOption]] = [:]
    private(set) var retention: RetentionSummary?
    private(set) var encryption: EncryptionSummary?
    /// The last audit export per steward in this session.
    var exports: [String: AuditExportSummary] = [:]
    /// The last steward imported from an export in this session.
    var imported: AuditImportSummary?
    /// The last failed governance write or read, phrased by the facade.
    var problem: String?

    func load(steward: String, from source: any GovernanceSource) async {
        if let policy = await attempt({ try await source.policySummary(steward: steward) }) {
            policies[steward] = policy
        }
        await loadRetention(from: source)
    }

    func load(run: String, from source: any GovernanceSource) async {
        if let options = await attempt({ try await source.undoOptions(run: run) }) {
            undo[run] = options
        }
    }

    func loadHome(from source: any GovernanceSource) async {
        await loadRetention(from: source)
        if let state = await attempt({ try await source.encryption() }) { encryption = state }
    }

    private func loadRetention(from source: any GovernanceSource) async {
        if let state = await attempt({ try await source.retention() }) { retention = state }
    }

    /// Aborts `run`; true when the facade recorded it.
    func abort(run: String, reason: String?, from source: any GovernanceSource) async -> Bool {
        let text = reason.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return await attempt({ try await source.abortRun(run, reason: text, as: "local") }) != nil
    }

    /// Requests the compensation for `option`; the summary says whether it ran or waits.
    func undo(_ option: UndoOption, from source: any GovernanceSource) async -> UndoSummary? {
        let result = await attempt {
            try await source.undoAction(
                run: option.run, action: option.action, reason: nil, as: "local")
        }
        await load(run: option.run, from: source)
        return result
    }

    func setRetention(steward: String?, days: Int?, from source: any GovernanceSource) async {
        if let state = await attempt({
            try await source.setRetention(steward: steward, days: days, as: "local")
        }) {
            retention = state
        }
    }

    func importAudit(from directory: URL, source: any GovernanceSource) async {
        if let summary = await attempt({
            try await source.importAudit(from: directory, as: "local")
        }) {
            imported = summary
        }
    }

    func applyRetention(from source: any GovernanceSource) async {
        if let state = await attempt({ try await source.applyRetention(as: "local") }) {
            retention = state
        }
    }

    func resealHistory(from source: any GovernanceSource) async {
        if let state = await attempt({ try await source.resealHistory(as: "local") }) {
            encryption = state
        }
    }

    func enableEncryption(from source: any GovernanceSource) async {
        if let state = await attempt({ try await source.enableEncryption(as: "local") }) {
            encryption = state
        }
    }

    /// Exports `steward`'s signed slice into a new folder inside `parent`.
    func export(steward: String, into parent: URL, from source: any GovernanceSource) async {
        let stamp = Int(Date().timeIntervalSince1970)
        let folder = parent.appendingPathComponent("\(steward)-audit-\(stamp)", isDirectory: true)
        if let summary = await attempt({
            try await source.exportAudit(steward: steward, to: folder, reveal: false, as: "local")
        }) {
            exports[steward] = summary
        }
    }

    /// The days a steward keeps, its own setting first.
    func retentionDays(steward: String) -> Int? {
        retention?.stewards.first { $0.steward == steward }?.days
    }

    private func attempt<T>(_ body: () async throws -> T) async -> T? {
        do {
            let value = try await body()
            problem = nil
            return value
        } catch {
            problem = FeatureStore.sentence(error)
            return nil
        }
    }
}
