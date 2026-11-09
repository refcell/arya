import Foundation

/// Process exit statuses, following the BSD `sysexits` conventions where one fits.
enum ExitStatus: Int32, Sendable {
    case ok = 0
    case failure = 1
    case usage = 64
    case dataError = 65
    case noInput = 66
    case unavailable = 69
}

/// Errors a command reports to the user. Each maps to one exit status.
enum CLIError: Error, Sendable, Equatable {
    /// The command line is wrong; `command` selects the usage line to print.
    case usage(String, command: CommandID? = nil)
    /// A piece arya needs has not been built yet, or is not installed.
    case unavailable(String)
    /// A named steward, run, approval, or file does not exist.
    case notFound(String)
    /// An input file or value is malformed.
    case invalidInput(String)
    /// The command ran and the outcome is a failure (for example a broken ledger).
    case failed(String)

    var status: ExitStatus {
        switch self {
        case .usage: .usage
        case .unavailable: .unavailable
        case .notFound: .noInput
        case .invalidInput: .dataError
        case .failed: .failure
        }
    }

    var message: String {
        switch self {
        case .usage(let text, _): text
        case .unavailable(let text): "not available yet: \(text)"
        case .notFound(let text): "not found: \(text)"
        case .invalidInput(let text): "invalid input: \(text)"
        case .failed(let text): text
        }
    }
}

/// A person's decision on a held action.
enum ApprovalDecision: String, Sendable, Codable, Equatable {
    case grant
    case deny
}

/// What the CLI needs from an arya home. The real implementation wraps `Arya.Workspace`; tests
/// use an in-memory fake. Results are CLI view models, so `--json` output stays stable even when
/// the facade's types change.
protocol CLIBackend: Sendable {
    func initHome() async throws(CLIError) -> InitReport
    func createSteward(charterPath: String) async throws(CLIError) -> StewardDetail
    func listStewards() async throws(CLIError) -> [StewardSummary]
    func showSteward(_ id: String) async throws(CLIError) -> StewardDetail
    func startRun(steward: String, input: String?) async throws(CLIError) -> RunReport
    func listApprovals(steward: String?, scope: ApprovalScope) async throws(CLIError)
        -> [ApprovalSummary]
    func decide(approval: String, decision: ApprovalDecision, note: String?)
        async throws(CLIError) -> ApprovalSummary
    func tailLedger(count: Int, steward: String?) async throws(CLIError) -> [EventSummary]
    func verifyLedger() async throws(CLIError) -> VerifyReport
}

/// Which approvals a listing includes.
enum ApprovalScope: Sendable, Equatable {
    case pending
    case all
}

/// Opens the backend for a home directory.
typealias BackendFactory = @Sendable (URL) -> any CLIBackend

/// The backend used until the `Workspace` facade lands in `Sources/Arya` (runtime lane). Every
/// command fails with a clear "not available yet" message and exit status 69, which `just e2e`
/// reports as a pending step. Delete this once `WorkspaceBackend` exists.
struct PendingBackend: CLIBackend {
    let home: URL

    private func pending(_ what: String) -> CLIError {
        .unavailable("\(what) needs the Workspace facade in Sources/Arya (runtime lane)")
    }

    func initHome() async throws(CLIError) -> InitReport { throw pending("arya init") }
    func createSteward(charterPath: String) async throws(CLIError) -> StewardDetail {
        throw pending("arya steward create")
    }
    func listStewards() async throws(CLIError) -> [StewardSummary] {
        throw pending("arya steward list")
    }
    func showSteward(_ id: String) async throws(CLIError) -> StewardDetail {
        throw pending("arya steward show")
    }
    func startRun(steward: String, input: String?) async throws(CLIError) -> RunReport {
        throw pending("arya run")
    }
    func listApprovals(steward: String?, scope: ApprovalScope) async throws(CLIError)
        -> [ApprovalSummary]
    { throw pending("arya approvals") }
    func decide(approval: String, decision: ApprovalDecision, note: String?)
        async throws(CLIError) -> ApprovalSummary
    { throw pending(decision == .grant ? "arya approve" : "arya deny") }
    func tailLedger(count: Int, steward: String?) async throws(CLIError) -> [EventSummary] {
        throw pending("arya ledger tail")
    }
    func verifyLedger() async throws(CLIError) -> VerifyReport {
        throw pending("arya ledger verify")
    }
}
