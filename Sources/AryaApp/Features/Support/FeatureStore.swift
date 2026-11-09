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

    /// Clears the last write error.
    func dismissWriteError() { writeError = nil }

    static func describe(_ error: any Error) -> String {
        switch error {
        case FeatureWriteError.unknownApproval(let id):
            return "Approval \(id) no longer exists. Reload the queue and try again."
        case FeatureWriteError.alreadyDecided(let id):
            return "Approval \(id) was already decided. Its result is in the ledger."
        default:
            return "Could not read the workspace: \(error.localizedDescription)"
        }
    }
}
