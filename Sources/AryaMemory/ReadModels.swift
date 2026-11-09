import AryaCore

/// One row of a steward's routine list (`arya routines`, the app's Routines view).
public struct RoutineOverview: Sendable, Equatable {
    public var name: String
    public var language: RoutineLanguage
    /// The live version, or nil when retired or only proposed.
    public var liveVersion: String?
    /// The newest proposed version.
    public var latestVersion: String
    /// Proposed versions, including the live one.
    public var versions: Int
    /// Versions never promoted.
    public var pending: Int
    /// Summary of the live version, else of the latest.
    public var summary: String
    /// Ledger `seq` of the routine's latest event.
    public var updatedSeq: Int
}

extension RoutineLibrary {
    /// Every routine a steward has proposed, sorted by name.
    public func overview(steward: StewardID) -> [RoutineOverview] {
        names(steward: steward).compactMap { name in
            let all = versions(steward: steward, name: name)
            guard let latest = all.last else { return nil }
            let live = live(steward: steward, name: name)
            let shown = live ?? latest
            return RoutineOverview(
                name: name, language: shown.language, liveVersion: live?.version,
                latestVersion: latest.version, versions: all.count,
                pending: all.filter { $0.promotedSeq == nil }.count, summary: shown.summary,
                updatedSeq: history(steward: steward, name: name).last?.seq ?? latest.proposedSeq)
        }
    }

    /// The diff between two stored versions of a routine, loading both from `store`.
    public func diff(
        steward: StewardID, name: String, from old: String, to new: String,
        store: some RoutineBlobStore
    ) throws -> RoutineDiff {
        func load(_ version: String) throws -> String {
            guard let found = self.version(steward: steward, name: name, version: version) else {
                throw RoutinePromotionError.unknownVersion(name: name, version: version)
            }
            return try found.content(from: store)
        }
        return RoutineDiff(old: try load(old), new: try load(new))
    }
}

extension MemoryProvenance {
    /// A one-line description for listings, for example
    /// `human:person:alex · case case-0007 · ev_9` or `steward:st_triage · run run_1`.
    public var line: String {
        var parts = ["\(author.kind.rawValue):\(author.id)"]
        if let run { parts.append("run \(run.rawValue)") }
        if let caseID { parts.append("case \(caseID.rawValue)") }
        if let event { parts.append(event.rawValue) }
        return parts.joined(separator: " · ")
    }
}

extension RoutineVersion {
    /// The first 12 hex digits of the version, for display.
    public var shortVersion: String { String(version.prefix(12)) }
}
