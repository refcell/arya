import AryaCore

/// Who wrote a memory note. Mirrors the ledger's actor kinds without depending on them.
public enum MemoryAuthorKind: String, Codable, Sendable, Equatable {
    case human
    case steward
    case adapter
    case system
}

/// The author of a memory note: a person (`person:alex`, `local`) or a steward.
public struct MemoryAuthor: Codable, Sendable, Equatable, Hashable {
    public var kind: MemoryAuthorKind
    public var id: String

    public init(kind: MemoryAuthorKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// The local user.
    public static let local = MemoryAuthor(kind: .human, id: "local")

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }
}

/// Where a memory note came from: the run and event that produced it, an optional case (for
/// corrections), and its author.
public struct MemoryProvenance: Codable, Sendable, Equatable, Hashable {
    public var run: RunID?
    public var event: EventID?
    public var caseID: CaseID?
    public var author: MemoryAuthor

    public init(
        run: RunID? = nil, event: EventID? = nil, caseID: CaseID? = nil,
        author: MemoryAuthor
    ) {
        self.run = run
        self.event = event
        self.caseID = caseID
        self.author = author
    }

    private enum CodingKeys: String, CodingKey {
        case run
        case event
        case caseID = "case"
        case author
    }
}

/// Reasons a memory note is rejected.
public enum MemoryNoteError: Error, Equatable, Sendable {
    case emptyText
    case textTooLong(bytes: Int, limit: Int)
}

/// A short text record a steward keeps across runs. Tags are normalized (trimmed, lowercased,
/// deduplicated, sorted) so equal notes encode to equal bytes.
public struct MemoryNote: Codable, Sendable, Equatable, Hashable {
    /// Largest accepted note text, in UTF-8 bytes.
    public static let maxTextBytes = 4096

    public var id: NoteID
    public var text: String
    public var tags: [String]
    public var provenance: MemoryProvenance

    /// Creates a validated note.
    public init(id: NoteID, text: String, tags: [String] = [], provenance: MemoryProvenance)
        throws(MemoryNoteError)
    {
        let trimmed = text.trimmingWhitespace()
        guard !trimmed.isEmpty else { throw .emptyText }
        let bytes = trimmed.utf8.count
        guard bytes <= Self.maxTextBytes else {
            throw .textTooLong(bytes: bytes, limit: Self.maxTextBytes)
        }
        self.id = id
        self.text = trimmed
        self.tags = Self.normalize(tags: tags)
        self.provenance = provenance
    }

    /// Trims, lowercases, drops empty, deduplicates, and sorts tags by UTF-8 bytes.
    public static func normalize(tags: [String]) -> [String] {
        let cleaned = tags.map { $0.trimmingWhitespace().lowercased() }.filter { !$0.isEmpty }
        return Set(cleaned).sorted { Array($0.utf8).lexicographicallyPrecedes($1.utf8) }
    }

    /// Decodes and validates a note, normalizing its tags.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: c.decode(NoteID.self, forKey: .id),
                text: c.decode(String.self, forKey: .text),
                tags: c.decodeIfPresent([String].self, forKey: .tags) ?? [],
                provenance: c.decode(MemoryProvenance.self, forKey: .provenance))
        } catch let error as MemoryNoteError {
            throw DecodingError.dataCorrupted(
                .init(codingPath: c.codingPath, debugDescription: "invalid note: \(error)"))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case tags
        case provenance
    }
}

extension String {
    func trimmingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let start = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else {
            return ""
        }
        guard let end = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else {
            return ""
        }
        return String(scalars[start...end])
    }
}
