import AryaCore
import AryaMemory
import AryaRuntime

/// A person's correction of one case, usually made while reviewing a rehearsal.
public struct CaseCorrection: Hashable, Sendable {
    public var caseID: CaseID
    /// What the steward should learn, kept as a memory note.
    public var text: String
    /// A new expected result; when set, the casebook gets a new version.
    public var expected: JSONValue?
    public var rehearsal: RehearsalID?
    public var run: RunID?

    public init(
        caseID: CaseID, text: String, expected: JSONValue? = nil, rehearsal: RehearsalID? = nil,
        run: RunID? = nil
    ) {
        self.caseID = caseID
        self.text = text
        self.expected = expected
        self.rehearsal = rehearsal
        self.run = run
    }
}

/// Payload of `case.corrected`.
public struct CaseCorrectedPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var casebook: String
    public var caseID: CaseID
    public var text: String
    public var expected: JSONValue?
    public var rehearsal: RehearsalID?
    public var run: RunID?

    enum CodingKeys: String, CodingKey {
        case v, casebook
        case caseID = "case"
        case text, expected, rehearsal, run
    }
}

/// What a correction recorded.
public struct CorrectionOutcome: Sendable {
    public var event: RuntimeEvent
    public var note: MemoryNote
    /// The corrected casebook, when the correction changed an expected result.
    public var casebook: Casebook?
}

extension Casebook {
    /// A copy with one case's expected result replaced; a new version.
    public func correcting(_ caseID: CaseID, expected: JSONValue) throws -> Casebook {
        guard cases.contains(where: { $0.id == caseID }) else {
            throw EvalError.unknownCase(caseID)
        }
        let updated = cases.map { item in
            var item = item
            if item.id == caseID { item.expected = expected }
            return item
        }
        return try Casebook(name: name, cases: updated)
    }
}

/// Records corrections: `case.corrected` and a `memory.added` note, both attributed to the
/// person, and, when the expected result changes, a new casebook version.
public struct Corrector: Sendable {
    public var sink: any EventSink
    public var blobs: any EvalBlobStore
    public var ambient: Ambient

    public init(sink: any EventSink, blobs: any EvalBlobStore, ambient: Ambient) {
        self.sink = sink
        self.blobs = blobs
        self.ambient = ambient
    }

    /// `person` is `local` or a binding contact id such as `person:alex`.
    public func correct(
        _ correction: CaseCorrection, in book: Casebook, steward: StewardID, person: String
    ) async throws -> CorrectionOutcome {
        guard book.cases.contains(where: { $0.id == correction.caseID }) else {
            throw EvalError.unknownCase(correction.caseID)
        }
        let actor = RuntimeActor.person(person)
        let payload = CaseCorrectedPayload(
            casebook: book.version, caseID: correction.caseID, text: correction.text,
            expected: correction.expected, rehearsal: correction.rehearsal, run: correction.run)
        let event = try await sink.append(
            RuntimeEventDraft(
                type: EvalEventType.caseCorrected, steward: steward, actor: actor,
                payload: try CanonicalJSON.jsonValue(payload)))
        let note = try MemoryCorrections.note(
            id: ambient.newID(NoteID.self), text: correction.text, person: person,
            caseID: correction.caseID, correctionEvent: event.id, run: correction.run)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: MemoryEventType.added, steward: steward, actor: actor,
                payload: try CanonicalJSON.jsonValue(MemoryAddedPayload(note: note))))
        var corrected: Casebook?
        if let expected = correction.expected {
            let next = try book.correcting(correction.caseID, expected: expected)
            if next.version != book.version {
                try await CasebookImporter(blobs: blobs, sink: sink).record(
                    next, steward: steward, actor: actor, correctedFrom: book.version)
                corrected = next
            }
        }
        return CorrectionOutcome(event: event, note: note, casebook: corrected)
    }
}
