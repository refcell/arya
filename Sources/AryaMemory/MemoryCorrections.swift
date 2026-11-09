import AryaCore

/// Turning a person's correction of a case into a memory note.
public enum MemoryCorrections {
    /// Tag every correction note carries.
    public static let tag = "correction"

    /// Tag linking a note to the case it corrects, so a rehearsal of that case can ask for it.
    public static func caseTag(_ caseID: CaseID) -> String { "case:\(caseID.rawValue)" }

    /// The note recorded alongside `case.corrected`. It is attributed to the correcting person
    /// (`person` is a binding contact id such as `person:alex`, or `local`) and points at the
    /// correction event and the case. `run` is the rehearsal run being corrected, if any.
    public static func note(
        id: NoteID, text: String, person: String, caseID: CaseID, correctionEvent: EventID,
        run: RunID? = nil, tags: [String] = []
    ) throws(MemoryNoteError) -> MemoryNote {
        try MemoryNote(
            id: id, text: text, tags: tags + [tag, caseTag(caseID)],
            provenance: MemoryProvenance(
                run: run, event: correctionEvent, caseID: caseID,
                author: MemoryAuthor(kind: .human, id: person)))
    }
}

extension MemoryNote {
    /// Whether this note came from a person's correction.
    public var isCorrection: Bool {
        provenance.author.kind == .human && tags.contains(MemoryCorrections.tag)
    }
}

extension MemoryProjection {
    /// Live correction notes of a steward, oldest first.
    public func corrections(steward: StewardID) -> [LiveNote] {
        liveNotes(steward: steward).filter(\.note.isCorrection)
    }
}
