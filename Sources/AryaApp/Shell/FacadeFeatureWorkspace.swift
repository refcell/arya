import Arya
import Foundation

/// Feeds the feature views (`FeatureWorkspace`) from the facade (`WorkspaceSource`), so a real
/// home shows the same views as preview mode. Payloads are decoded from the canonical JSON text
/// the facade returns; writes the facade has no call for report "cannot do that yet".
struct FacadeFeatureWorkspace: FeatureWorkspace {
    let source: any WorkspaceSource

    func events() async throws -> [FeatureEvent] {
        try await source.ledger(from: 1, limit: nil).map(Self.event)
    }

    @discardableResult
    func record(_ write: FeatureWrite) async throws -> [FeatureEvent] {
        switch write {
        case .approve(let approval):
            _ = try await source.approve(approval, note: nil)
        case .deny(let approval, let reason):
            _ = try await source.deny(approval, note: reason.isEmpty ? nil : reason)
        default:
            throw WorkspaceError.unavailable("\(write)")
        }
        // The store reloads every event after a write, so the appended events are not needed.
        return []
    }

    func verify() async throws -> FeatureVerifyResult {
        let check = try await source.verifyLedger()
        if check.ok { return .intact(events: check.events) }
        return .broken(seq: check.firstBadSeq ?? 0, reason: check.detail ?? "unknown")
    }

    func changes() -> AsyncStream<Void> {
        let events = source.events(from: 1)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await _ in events { continuation.yield() }
                } catch {
                    // The shell reports a stopped stream through `AppModel.live`.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A facade ledger entry as a feature event. An undecodable payload becomes `null`.
    static func event(_ entry: LedgerEntry) -> FeatureEvent {
        let payload = (try? JSONDecoder().decode(FeatureJSON.self, from: Data(entry.payload.utf8)))
        return FeatureEvent(
            seq: entry.seq, id: entry.id, at: entry.at, steward: entry.steward, run: entry.run,
            actor: FeatureActor(
                kind: FeatureActor.Kind(rawValue: entry.actorKind) ?? .system, id: entry.actorID),
            type: entry.type, payload: payload ?? .null)
    }
}
