import AryaCore
import AryaLedger

/// A note as a run's `run/result` proposes it (`memories[]` in PROTOCOL.md). The runtime
/// converts the adapter's type into this one, so memory does not depend on adapters.
public struct ProposedNote: Sendable, Equatable {
    public var text: String
    public var tags: [String]

    public init(text: String, tags: [String] = []) {
        self.text = text
        self.tags = tags
    }
}

/// What intake did with a run's proposed notes.
public struct MemoryIntake: Sendable {
    /// One `memory.added` draft per accepted note, in result order.
    public var drafts: [EventDraft]
    public var accepted: [MemoryNote]
    /// Notes that failed validation, by their index in the result.
    public var rejected: [(index: Int, error: MemoryNoteError)]
    /// Indexes of notes whose normalized text equals a live note's (or an earlier note in the
    /// same result); they are not added again.
    public var duplicates: [Int]

    /// Turns a run's proposed notes into `memory.added` drafts authored by the steward, with
    /// the run (and, when known, the event that carried the result) as provenance. Note ids
    /// come from `ambient`, so replay with a recorded ambient yields the same ids.
    public static func notes(
        _ proposed: [ProposedNote], steward: StewardID, run: RunID, resultEvent: EventID? = nil,
        live: MemoryProjection, ambient: Ambient
    ) throws -> MemoryIntake {
        var intake = MemoryIntake(drafts: [], accepted: [], rejected: [], duplicates: [])
        var texts = Set(live.liveNotes(steward: steward).map { Self.key($0.note.text) })
        let author = MemoryAuthor(kind: .steward, id: steward.rawValue)
        for (index, item) in proposed.enumerated() {
            guard texts.insert(Self.key(item.text)).inserted else {
                intake.duplicates.append(index)
                continue
            }
            let note: MemoryNote
            do {
                note = try MemoryNote(
                    id: ambient.newID(NoteID.self), text: item.text, tags: item.tags,
                    provenance: MemoryProvenance(run: run, event: resultEvent, author: author))
            } catch {
                intake.rejected.append((index, error))
                continue
            }
            intake.accepted.append(note)
            intake.drafts.append(try .memoryAdded(note, steward: steward))
        }
        return intake
    }

    /// Duplicate detection compares trimmed text exactly; casing and inner spacing matter.
    private static func key(_ text: String) -> String { text.trimmingWhitespace() }
}
