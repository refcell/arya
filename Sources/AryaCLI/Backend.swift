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
protocol CLIBackend:
    ImprovementBackend, HistoryBackend, PeopleBackend, GovernanceBackend, LiveBackend,
    StewardReadBackend, FindingTemplateBackend, RoutineLibraryBackend
{
    func initHome() async throws(CLIError) -> InitReport
    func createSteward(charterPath: String) async throws(CLIError) -> StewardDetail
    func listStewards() async throws(CLIError) -> [StewardRow]
    /// Every active or paused steward's outcome, those needing a person first.
    func fleet() async throws(CLIError) -> [FleetRow]
    func showSteward(_ id: String) async throws(CLIError) -> StewardDetail
    /// Pauses a steward and returns it as it is now.
    func pauseSteward(_ id: String) async throws(CLIError) -> StewardDetail
    /// Resumes a paused steward and returns it as it is now.
    func resumeSteward(_ id: String) async throws(CLIError) -> StewardDetail
    func startRun(steward: String, input: String?) async throws(CLIError) -> RunReport
    func showRun(_ id: String) async throws(CLIError) -> RunReport
    /// Asks arya to stop a running run; returns the run as the ledger now says.
    func abortRun(_ id: String, reason: String?) async throws(CLIError) -> RunReport
    /// Fires triggers every `every` seconds until the process stops.
    func serve(every: Int) async throws(CLIError)
    /// `serve`, with paced demo runs when `demoPace` (runtime decision 0051).
    func serve(every: Int, demoPace: Bool) async throws(CLIError)
    func installLoginItem(every: Int) async throws(CLIError) -> LoginItemReport
    func uninstallLoginItem() async throws(CLIError) -> LoginItemReport
    func listApprovals(steward: String?, scope: ApprovalScope) async throws(CLIError)
        -> [ApprovalRow]
    /// Grants or denies; `person` (default `local`) must be allowed by the approver rules.
    func decide(approval: String, decision: ApprovalDecision, note: String?, as person: String?)
        async throws(CLIError) -> ApprovalRow
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

extension CLIBackend {
    func serve(every: Int, demoPace: Bool) async throws(CLIError) {
        try await serve(every: every)
    }

    /// `steward onboard` (runtime decision 0059).
    func onboard(_ steward: String) async throws(CLIError) -> OnboardReport {
        throw .unavailable("Workspace.onboard (runtime lane)")
    }
}

/// What `steward onboard` learned (runtime decision 0059).
struct OnboardReport: Codable, Sendable, Equatable {
    var steward: String
    /// The onboard run, absent when the steward has no onboarding source.
    var run: String?
    var sources: [String] = []
    var notes = 0
    var duplicates = 0
    var people = 0
    var queues = 0
    var rules = 0
    var documents = 0
    var failed = 0
}
