import Combine
import Foundation

/// Loading state shared by every feature view.
enum FeatureLoadState<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)
}

/// The app-side model the feature views observe: the workspace's events, reloaded whenever
/// the workspace reports a change, plus the last write error to show the person.
@MainActor
final class FeatureStore: ObservableObject {
    let workspace: any FeatureWorkspace
    @Published private(set) var state: FeatureLoadState<[FeatureEvent]> = .loading
    @Published private(set) var writeError: String?
    /// The last ledger verification, or nil before the person runs one.
    @Published private(set) var verifyResult: FeatureVerifyResult?
    @Published private(set) var isVerifying = false
    /// The reference time for relative timestamps. Tests and previews pin it.
    @Published var now: Date

    init(workspace: any FeatureWorkspace, now: Date = Date()) {
        self.workspace = workspace
        self.now = now
    }

    /// The loaded events, or none while loading or after a failure.
    var events: [FeatureEvent] {
        if case .loaded(let events) = state { return events }
        return []
    }

    /// Loads all events.
    func reload() async {
        do {
            state = .loaded(try await workspace.events())
        } catch {
            state = .failed(FeatureStore.describe(error))
        }
    }

    /// Reloads once now, then on every change until the task is cancelled.
    func observe() async {
        await reload()
        for await _ in workspace.changes() {
            await reload()
        }
    }

    /// Records a write and reloads. Returns whether it succeeded; failures land in
    /// `writeError`.
    @discardableResult
    func perform(_ write: FeatureWrite) async -> Bool {
        do {
            try await workspace.record(write)
            writeError = nil
            await reload()
            return true
        } catch {
            writeError = FeatureStore.describe(error)
            return false
        }
    }

    /// Verifies the ledger's hash chain and keeps the result. A failure to run the check at
    /// all lands in `writeError`.
    func verify() async {
        isVerifying = true
        defer { isVerifying = false }
        do {
            verifyResult = try await workspace.verify()
        } catch {
            verifyResult = nil
            writeError = FeatureStore.describe(error)
        }
    }

    /// Clears the last write error.
    func dismissWriteError() { writeError = nil }

    static func describe(_ error: any Error) -> String {
        switch error {
        case FeatureWriteError.unknownApproval(let id):
            return "Approval \(id) no longer exists. Reload the queue and try again."
        case FeatureWriteError.alreadyDecided(let id):
            return "Approval \(id) was already decided. Its result is in the ledger."
        case FeatureWriteError.unknownProposal(let id):
            return "Proposal \(id) no longer exists. Reload the changes and try again."
        case FeatureWriteError.proposalClosed(let id):
            return "Proposal \(id) was already accepted or rejected."
        case FeatureWriteError.gateNotPassed(let id):
            return "Proposal \(id) has not passed its gate. Rehearse it again, or override."
        case FeatureWriteError.gatePassed(let id):
            return "Proposal \(id) passed its gate; accept it instead of overriding."
        case FeatureWriteError.unknownNote(let id):
            return "Memory note \(id) no longer exists. Reload memory and try again."
        case FeatureWriteError.alreadyRetracted(let id):
            return "Memory note \(id) was already retracted."
        default:
            return "Could not read the workspace: \(error.localizedDescription)"
        }
    }
}
