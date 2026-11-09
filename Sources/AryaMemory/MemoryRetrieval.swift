import AryaCore

/// What a run asks memory for: tags of interest and size caps. Sizes are UTF-8 bytes of note
/// text, so results do not depend on the Unicode version of the toolchain.
public struct MemoryQuery: Codable, Sendable, Equatable {
    public static let defaultMaxNotes = 20
    public static let defaultMaxCharacters = 4000

    public var tags: [String]
    public var maxNotes: Int
    public var maxCharacters: Int

    public init(
        tags: [String] = [], maxNotes: Int = defaultMaxNotes,
        maxCharacters: Int = defaultMaxCharacters
    ) {
        self.tags = MemoryNote.normalize(tags: tags)
        self.maxNotes = max(0, maxNotes)
        self.maxCharacters = max(0, maxCharacters)
    }

    private enum CodingKeys: String, CodingKey {
        case tags
        case maxNotes
        case maxCharacters
    }
}

/// The notes a run saw, in the order it saw them. `run.started` records it for replay.
public struct MemorySnapshot: Codable, Sendable, Equatable {
    public var v: Int
    public var notes: [NoteID]

    public init(notes: [NoteID]) {
        self.v = 1
        self.notes = notes
    }

    public static let empty = MemorySnapshot(notes: [])

    private enum CodingKeys: String, CodingKey {
        case v
        case notes
    }
}

/// Reasons a recorded snapshot cannot be resolved.
public enum MemorySnapshotError: Error, Equatable, Sendable {
    case unknownNote(NoteID)
}

/// Deterministic retrieval: no model, no clock, no randomness.
public enum MemoryRetrieval {
    /// Ranks notes and applies the caps. Notes sharing more tags with the query come first;
    /// ties and untagged matches go newest first (higher ledger `seq`), then by id. Notes are
    /// taken in rank order while fewer than `maxNotes` are taken; a note whose text would pass
    /// `maxCharacters` is skipped and smaller later notes may still fit.
    public static func retrieve(_ notes: [LiveNote], query: MemoryQuery) -> [LiveNote] {
        let wanted = Set(query.tags)
        let ranked = notes.map { note in
            (note: note, matches: note.note.tags.filter { wanted.contains($0) }.count)
        }.sorted { a, b in
            if a.matches != b.matches { return a.matches > b.matches }
            if a.note.seq != b.note.seq { return a.note.seq > b.note.seq }
            return a.note.note.id < b.note.note.id
        }
        var taken: [LiveNote] = []
        var used = 0
        for entry in ranked {
            guard taken.count < query.maxNotes else { break }
            let size = entry.note.note.text.utf8.count
            guard used + size <= query.maxCharacters else { continue }
            taken.append(entry.note)
            used += size
        }
        return taken
    }

    /// The memory section composed into a run's instructions. Empty when there are no notes.
    public static func render(_ notes: [LiveNote]) -> String {
        guard !notes.isEmpty else { return "" }
        let lines = notes.map { live -> String in
            let tags = live.note.tags.isEmpty ? "" : " [\(live.note.tags.joined(separator: ", "))]"
            return "- \(live.note.id)\(tags): \(live.note.text)"
        }
        return (["Memory:"] + lines).joined(separator: "\n")
    }
}

extension MemoryProjection {
    /// Retrieves a steward's live notes for a run.
    public func retrieve(steward: StewardID, query: MemoryQuery) -> [LiveNote] {
        MemoryRetrieval.retrieve(liveNotes(steward: steward), query: query)
    }

    /// The snapshot to record on `run.started`.
    public func snapshot(steward: StewardID, query: MemoryQuery) -> MemorySnapshot {
        MemorySnapshot(notes: retrieve(steward: steward, query: query).map(\.note.id))
    }

    /// Resolves a recorded snapshot to notes, in order, including notes retracted since.
    public func resolve(_ snapshot: MemorySnapshot, steward: StewardID)
        throws(MemorySnapshotError) -> [LiveNote]
    {
        try snapshot.notes.map { id throws(MemorySnapshotError) in
            guard let note = addedNote(steward: steward, id: id) else {
                throw .unknownNote(id)
            }
            return note
        }
    }
}
