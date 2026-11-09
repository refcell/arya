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
    /// The workspace's policy sentence and change line for each pending approval, by id;
    /// empty when the workspace cannot provide them.
    @Published private(set) var approvalTexts: [String: FeatureApprovalText] = [:]
    /// Event details read from the workspace (payload text, hash, prev, run step), by seq.
    @Published private(set) var eventDetails: [Int: FeatureEventDetail] = [:]
    /// The reference time for relative timestamps. Tests and previews pin it.
    @Published var now: Date
    /// The Knowledge screen per steward, kept so the tab draws at once on return.
    @Published var knowledge: [String: FeatureKnowledge] = [:]

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
            approvalTexts = (try? await workspace.approvalTexts()) ?? [:]
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
    /// Reads one event's detail once; ledger events never change, so it stays cached.
    func loadEventDetail(seq: Int) async {
        guard eventDetails[seq] == nil,
            let detail = try? await workspace.eventDetail(seq: seq)
        else { return }
        eventDetails[seq] = detail
    }

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

    nonisolated static func describe(_ error: any Error) -> String {
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
        case FeatureReadError.unavailable(let what):
            return "This workspace cannot show \(what) yet."
        case FeatureWriteError.staleCharter(let live):
            return "The charter changed to version \(live) while you edited. Reload and edit again."
        case FeatureWriteError.answerEmpty:
            return "Write an answer before sending it."
        case FeatureWriteError.correctionEmpty:
            return "Write what the steward should have done, then record the correction."
        case FeatureWriteError.unknownNote(let id):
            return "Memory note \(id) no longer exists. Reload memory and try again."
        case FeatureWriteError.alreadyRetracted(let id):
            return "Memory note \(id) was already retracted."
        default:
            return sentence(error)
        }
    }

    /// An error the seam does not know, as one plain sentence: its own description when it
    /// has one (the facade's errors say what failed), never an enum's localized placeholder.
    nonisolated static func sentence(_ error: any Error) -> String {
        let text: String
        let kind = type(of: error)
        if kind is CustomStringConvertible.Type, !(kind is NSError.Type) {
            text = String(describing: error)
        } else {
            let localized =
                (error as NSError).localizedFailureReason
                ?? (error as NSError).localizedDescription
            text =
                localized.contains("error 0") || localized.contains("couldn’t be completed")
                ? "Something went wrong (\(String(describing: type(of: error))))" : localized
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "Something went wrong." }
        let capitalized = first.uppercased() + trimmed.dropFirst()
        return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }
}
