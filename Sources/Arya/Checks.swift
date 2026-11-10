import AryaCore
import AryaEval
import AryaRuntime
import Foundation

extension Workspace {
    /// The checks people taught a steward through corrections and review-queue agreements,
    /// versioned and scored on its newest live rehearsal; `nil` before anyone reviewed a case.
    /// Each correction and review rebuilds them, so the newest version is always current.
    public func learnedChecks(steward: String) async throws -> LearnedChecksSummary? {
        let id = try await existing(steward).id
        return try await LearnedChecks(sink: sink, casebooks: casebookSource).view(steward: id)
    }

    /// Records a new version of the steward's learned checks when its corrections or
    /// agreements changed them.
    func rebuildChecks(_ steward: StewardID, by person: String) async throws {
        try await LearnedChecks(sink: sink, casebooks: casebookSource)
            .build(steward: steward, actor: .person(person))
    }
}

/// A steward's learned checks, scored, as the CLI and app read them.
public typealias LearnedChecksSummary = LearnedChecksView
/// One learned check and whether the newest live rehearsal passes it.
public typealias LearnedCheckLine = LearnedCheckResult
