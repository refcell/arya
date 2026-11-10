import AryaCore
import AryaRuntime
import Foundation

// Proactive findings (runtime decision 0054): problems and opportunities stewards noticed on
// their wakes, for the Overview, and those that need a person, for Needs you.

/// A finding as the app shows it.
public struct FindingSummary: Sendable, Hashable, Codable, Identifiable {
    /// `<run>/<finding>`.
    public var id: String
    public var steward: String
    public var run: String
    public var finding: String
    /// `problem` or `opportunity`.
    public var kind: String
    public var title: String
    public var evidence: [String]
    /// The suggested action in one line (`kind target`), when there is one.
    public var suggestion: String?
    public var needsPerson: Bool
    public var raisedAt: Date
    /// `acted` or `dismissed` once a person resolved it.
    public var resolution: String?
}

extension Workspace {
    /// Findings, newest first: open ones only unless `all`, for one steward or every steward.
    public func findings(steward: String? = nil, all: Bool = false) async throws
        -> [FindingSummary]
    {
        var id: StewardID?
        if let steward { id = try await existing(steward).id }
        let book = try FindingBook(try await sink.events(from: 1))
        return book.all.reversed().filter {
            (all || $0.isOpen) && (id == nil || $0.steward == id)
        }.map { record in
            let suggestion = record.raised.suggestion.map { action in
                [action.kind, action.target].compactMap { $0 }.joined(separator: " ")
            }
            return FindingSummary(
                id: record.run.rawValue + "/" + record.raised.finding,
                steward: record.steward.rawValue, run: record.run.rawValue,
                finding: record.raised.finding, kind: record.raised.kind, title: record.title,
                evidence: record.raised.evidence, suggestion: suggestion,
                needsPerson: record.raised.needsPerson, raisedAt: record.raisedAt.date,
                resolution: record.resolution)
        }
    }

    /// Resolves a finding (`acted` or `dismissed`) as `person`.
    public func resolveFinding(
        _ id: String, resolution: String, note: String? = nil, by person: String = "local"
    ) async throws {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw WorkspaceError.notFound(id) }
        do {
            try await FindingBook.resolve(
                parts[1], run: RunID(unchecked: parts[0]), resolution: resolution, note: note,
                by: .person(person), sink: sink)
        } catch FindingError.notFound {
            throw WorkspaceError.notFound(id)
        } catch FindingError.alreadyResolved {
            throw WorkspaceError.rejected("\(id) is already resolved")
        } catch FindingError.invalidResolution(let word) {
            throw WorkspaceError.rejected("resolution must be acted or dismissed, not \(word)")
        }
    }
}
