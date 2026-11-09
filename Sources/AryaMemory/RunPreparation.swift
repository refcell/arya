import AryaCore

/// What memory and routines contribute to a run before it starts: the snapshot and live
/// routine versions that `run.started` records, and the lines the instruction composer shows.
public struct RunMemoryContext: Sendable, Equatable {
    public var snapshot: MemorySnapshot
    public var notes: [LiveNote]
    /// Live routine versions by name.
    public var routineVersions: [String: String]
    public var routines: [RoutineVersion]

    /// The snapshot as the `memory` field of `run.started`.
    public var snapshotJSON: JSONValue {
        .object([
            "v": .int(Int64(snapshot.v)),
            "notes": .array(
                snapshot.notes.map {
                    .string($0.rawValue)
                }),
        ])
    }
}

extension MemoryQuery {
    /// A deterministic query for a run: the case tag for case runs, plus every known tag that
    /// appears as a word in the input text. Words are maximal runs of letters, digits, `-`,
    /// `_`, `:`, and `.`, compared lowercased; trailing dots are dropped.
    public static func forRun(
        inputText: String, caseID: CaseID? = nil, knownTags: some Sequence<String>,
        maxNotes: Int = defaultMaxNotes, maxCharacters: Int = defaultMaxCharacters
    ) -> MemoryQuery {
        let words = Set(Self.words(inputText.lowercased()))
        var tags = Set(knownTags).filter { words.contains($0) }
        if let caseID { tags.insert(MemoryCorrections.caseTag(caseID)) }
        return MemoryQuery(tags: Array(tags), maxNotes: maxNotes, maxCharacters: maxCharacters)
    }

    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            while current.hasSuffix(".") { current.removeLast() }
            if !current.isEmpty { out.append(current) }
            current = ""
        }
        for scalar in text.unicodeScalars {
            if scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                || "-_:.".unicodeScalars.contains(scalar)
            {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}

extension MemoryProjection {
    /// Every tag on a steward's live notes, sorted.
    public func tags(steward: StewardID) -> [String] {
        Set(liveNotes(steward: steward).flatMap(\.note.tags)).sorted()
    }
}

extension RoutineLibrary {
    /// Live routine versions by name, as `run.started` records them.
    public func liveVersions(steward: StewardID) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: liveRoutines(steward: steward).map {
                ($0.name, $0.version)
            })
    }
}

/// Builds a run's memory context from the projections.
public enum RunPreparation {
    public static func context(
        steward: StewardID, inputText: String, caseID: CaseID? = nil,
        memory: MemoryProjection, routines: RoutineLibrary,
        maxNotes: Int = MemoryQuery.defaultMaxNotes,
        maxCharacters: Int = MemoryQuery.defaultMaxCharacters
    ) -> RunMemoryContext {
        let query = MemoryQuery.forRun(
            inputText: inputText, caseID: caseID, knownTags: memory.tags(steward: steward),
            maxNotes: maxNotes, maxCharacters: maxCharacters)
        let notes = memory.retrieve(steward: steward, query: query)
        let live = routines.liveRoutines(steward: steward)
        return RunMemoryContext(
            snapshot: MemorySnapshot(notes: notes.map(\.note.id)), notes: notes,
            routineVersions: routines.liveVersions(steward: steward), routines: live)
    }
}
