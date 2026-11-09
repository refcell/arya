import Foundation

/// An opened arya home: the only API the CLI and the app use.
///
/// `Workspace.open(home:)` creates the home layout (ARCHITECTURE.md "Home directory") and wires
/// the ledger, adapters, memory, runtime, and eval modules. Every write records ledger events
/// with the local user as actor. Ids are plain strings (`st_…`, `run_…`, `ap_…`).
///
/// Calls whose backing module has not landed yet throw `WorkspaceError.unavailable`; the
/// signatures are stable so callers can be written against them today.
public actor Workspace {
    /// The home directory this workspace reads and writes.
    public nonisolated let home: URL

    private init(home: URL) {
        self.home = home
    }

    /// Opens the home at `home`, creating its directories when missing.
    ///
    /// The caller (CLI or app entry point) resolves the home path, for example from
    /// `ARYA_HOME`; this library never reads environment variables.
    public static func open(home: URL) async throws -> Workspace {
        try HomeLayout.create(at: home)
        return Workspace(home: home)
    }

    // MARK: Stewards

    /// All stewards, sorted by id, including paused and retired ones.
    public func stewards() async throws -> [StewardSummary] {
        throw WorkspaceError.unavailable("stewards")
    }

    /// One steward, or `nil` if no steward has this id.
    public func steward(_ id: String) async throws -> StewardSummary? {
        throw WorkspaceError.unavailable("steward")
    }

    /// Records a new steward from charter JSON (`steward.created`, version 1).
    public func createSteward(charter: Data) async throws -> StewardSummary {
        throw WorkspaceError.unavailable("createSteward")
    }

    /// Pauses a steward so it takes no live triggers (`steward.paused`).
    public func pauseSteward(_ id: String) async throws {
        throw WorkspaceError.unavailable("pauseSteward")
    }

    /// Resumes a paused steward (`steward.resumed`).
    public func resumeSteward(_ id: String) async throws {
        throw WorkspaceError.unavailable("resumeSteward")
    }

    /// Retires a steward for good (`steward.retired`).
    public func retireSteward(_ id: String) async throws {
        throw WorkspaceError.unavailable("retireSteward")
    }

    // MARK: Runs

    /// Starts a manual run with `input` as its text and waits until it finishes or fails.
    /// Approvals it requests stay pending after it returns.
    public func startRun(steward: String, input: String) async throws -> RunSummary {
        throw WorkspaceError.unavailable("startRun")
    }

    /// Runs, newest first, optionally for one steward.
    public func runs(steward: String? = nil) async throws -> [RunSummary] {
        throw WorkspaceError.unavailable("runs")
    }

    // MARK: Approvals

    /// Approvals, oldest first; pending only unless `includeDecided` is true.
    public func approvals(includeDecided: Bool = false) async throws -> [ApprovalSummary] {
        throw WorkspaceError.unavailable("approvals")
    }

    /// Grants a pending approval; an action then executes and its output is recorded. For a
    /// question, `note` is the answer.
    public func approve(_ id: String, note: String? = nil) async throws -> ApprovalSummary {
        throw WorkspaceError.unavailable("approve")
    }

    /// Denies a pending approval (`approval.denied`, then `action.rejected`).
    public func deny(_ id: String, note: String? = nil) async throws -> ApprovalSummary {
        throw WorkspaceError.unavailable("deny")
    }

    // MARK: Ledger

    /// Ledger entries with `seq >= from`, in order, at most `limit` of them.
    public func ledger(from seq: Int = 1, limit: Int? = nil) async throws -> [LedgerEntry] {
        throw WorkspaceError.unavailable("ledger")
    }

    /// Entries with `seq >= from`, then every new entry as it is appended, by any process.
    public nonisolated func events(from seq: Int = 1) -> AsyncThrowingStream<LedgerEntry, Error> {
        AsyncThrowingStream { $0.finish(throwing: WorkspaceError.unavailable("events")) }
    }

    /// Verifies the hash chain, `seq` continuity, and envelopes.
    public func verifyLedger() async throws -> LedgerCheck {
        throw WorkspaceError.unavailable("verifyLedger")
    }
}

/// Errors the facade reports.
public enum WorkspaceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The call's backing module has not landed yet.
    case unavailable(String)
    /// No steward, run, or approval has this id.
    case notFound(String)
    /// The request was rejected, for example an invalid charter or an approval already decided.
    case rejected(String)

    public var description: String {
        switch self {
        case .unavailable(let call): "\(call) is not available yet"
        case .notFound(let id): "not found: \(id)"
        case .rejected(let detail): detail
        }
    }
}

/// Creates the directories of an arya home.
enum HomeLayout {
    static let directories = ["ledger", "blobs", "casebooks", "cache"]

    static func create(at home: URL) throws {
        for name in directories {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }
}
