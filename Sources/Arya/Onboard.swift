import AryaCore
import AryaRuntime
import Foundation

// Self-onboarding (runtime decision 0059): what a steward learned from its connected systems'
// people and process, for the onboarding view and `arya steward onboard`.

/// A steward's latest onboarding.
public struct OnboardSummary: Sendable, Hashable, Codable {
    public var steward: String
    /// The onboard run.
    public var run: String
    public var at: Date
    /// Bindings read without error.
    public var sources: [String]
    /// Notes added; `duplicates` were already known.
    public var notes: Int
    public var duplicates: Int
    public var people: Int
    public var queues: Int
    public var rules: Int
    public var documents: Int
    /// Tool calls that failed.
    public var failed: Int
}

extension Workspace {
    /// Runs an onboard run of `steward` now. Nil when its charter has no binding that lists
    /// the `directory` or `process` read tool.
    @discardableResult
    public func onboard(steward: String, by person: String = "local") async throws
        -> OnboardSummary?
    {
        let id = try await existing(steward).id
        guard
            try await mapped({
                try await engine.onboard(
                    id, connect: engine.connect ?? BindingActionExecutor.spawn,
                    actor: .person(person))
            }) != nil
        else { return nil }
        return try await onboarding(steward: steward)
    }

    /// `steward`'s latest onboarding, or nil if it never onboarded.
    public func onboarding(steward: String) async throws -> OnboardSummary? {
        let id = try await existing(steward).id
        guard let latest = try Onboarding.latest(id, in: try await sink.events(from: 1)) else {
            return nil
        }
        let done = latest.completed
        return OnboardSummary(
            steward: id.rawValue, run: latest.run.rawValue, at: latest.at.date,
            sources: done.sources, notes: done.notes, duplicates: done.duplicates,
            people: done.people, queues: done.queues, rules: done.rules,
            documents: done.documents, failed: done.failed)
    }
}
