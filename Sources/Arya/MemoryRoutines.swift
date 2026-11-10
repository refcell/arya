import AryaCore
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation

// Memory notes and routines, read from the ledger through `AryaMemory`'s projections, with
// routine bodies from the home's blobs.

/// A memory note as listings show it.
public struct MemorySummary: Sendable, Hashable, Codable {
    public var id: String
    public var steward: String
    public var text: String
    public var tags: [String]
    /// Who wrote it: `human:local`, `steward:st_…`, ...
    public var author: String
    /// Run that wrote it, if any.
    public var run: String?
    /// Case it came from (corrections), if any.
    public var caseID: String?
    /// Event that carried it, if recorded.
    public var event: String?
    /// True once retracted; retracted notes no longer reach runs.
    public var retracted: Bool
    /// Ledger `seq` of `memory.added`.
    public var seq: Int

    /// True for a note every steward recalls (`steward` is the shared scope).
    public var shared: Bool { steward == MemoryScope.shared.rawValue }
    /// The person a preference is about (its `person:<id>` tag), for notes tagged `preference`.
    public var about: String? {
        guard tags.contains("preference") else { return nil }
        return tags.first { $0.hasPrefix("person:") }
    }
}

/// One routine of a steward.
public struct RoutineSummary: Sendable, Hashable, Codable {
    public var name: String
    /// `sh` or `prompt` (`RoutineLanguage`).
    public var language: String
    /// The live version, if one was promoted.
    public var liveVersion: String?
    public var latestVersion: String
    public var versions: Int
    /// Versions proposed and not promoted.
    public var pending: Int
    public var summary: String
}

/// One routine version with its body and provenance.
public struct RoutineDetail: Sendable, Hashable, Codable {
    /// Where a version stands with respect to its gate.
    public enum GateStatus: String, Sendable, Hashable, Codable {
        /// The version runs today.
        case live
        /// Was live once and was replaced or retired.
        case superseded
        /// Proposed and not promoted (waiting for or refused by its gate).
        case pending
    }

    public var steward: String
    public var name: String
    /// Content hash of the body.
    public var version: String
    public var language: String
    /// The body; `nil` when its blob is missing.
    public var content: String?
    public var bytes: Int
    public var summary: String
    /// Why it was proposed.
    public var reason: String?
    /// The run that proposed it, if any (else a person did).
    public var run: String?
    /// The proposal that promoted it, if recorded.
    public var proposal: String?
    public var gate: GateStatus
    /// Ledger `seq` of `routine.proposed` and of the last `routine.promoted`.
    public var proposedSeq: Int
    public var promotedSeq: Int?
}

/// One step of a routine's history.
public struct RoutineHistoryItem: Sendable, Hashable, Codable {
    /// `proposed`, `promoted`, or `retired`.
    public var kind: String
    public var version: String
    public var seq: Int
    public var at: Date
}

extension Workspace {
    // MARK: Memory

    /// A steward's memory notes in ledger order; live ones only unless `includeRetracted`.
    public func memory(steward: String, includeRetracted: Bool = false) async throws
        -> [MemorySummary]
    {
        let id = try await existing(steward).id
        let projection = try MemoryProjection(ledger: try facadeState().events)
        return projection.allNotes(steward: id)
            .filter { includeRetracted || !$0.retracted }
            .map { MemorySummary($0.note, retracted: $0.retracted) }
    }

    /// Records a memory note written by `person`: under `steward`, or shared by every steward
    /// when `steward` is nil. With `about`, a person binding id such as `person:alex`, the note
    /// is that person's preference (tags `preference` and the id).
    @discardableResult
    public func remember(
        _ text: String, steward: String? = nil, about: String? = nil, tags: [String] = [],
        by person: String = "local"
    ) async throws -> MemorySummary {
        var scope = MemoryScope.shared
        if let steward { scope = try await existing(steward).id }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.rejected("a note needs text") }
        var allTags: [String] = []
        func add(_ tag: String) { if !allTags.contains(tag) { allTags.append(tag) } }
        tags.forEach(add)
        if let about {
            guard about.hasPrefix("person:"), about.count > "person:".count else {
                throw WorkspaceError.rejected("about must be a person binding id, not \(about)")
            }
            add("preference")
            add(about)
        }
        let note: MemoryNote
        do {
            note = try MemoryNote(
                id: ambient.newID(NoteID.self), text: trimmed,
                tags: allTags,
                provenance: MemoryProvenance(author: MemoryAuthor(kind: .human, id: person)))
        } catch {
            throw WorkspaceError.rejected(String(describing: error))
        }
        let event = try await sink.append(
            RuntimeEventDraft(
                type: MemoryEventType.added, steward: scope, actor: .person(person),
                payload: try CanonicalJSON.decode(
                    JSONValue.self,
                    from: try CanonicalJSON.encode(MemoryAddedPayload(note: note)))))
        return MemorySummary(
            LiveNote(steward: scope, seq: event.seq, note: note), retracted: false)
    }

    /// Notes every steward recalls; live ones only unless `includeRetracted`.
    public func sharedMemory(includeRetracted: Bool = false) async throws -> [MemorySummary] {
        try MemoryProjection(ledger: try facadeState().events).allNotes(steward: MemoryScope.shared)
            .filter { includeRetracted || !$0.retracted }
            .map { MemorySummary($0.note, retracted: $0.retracted) }
    }

    /// Live preferences about `person` (a binding id such as `person:alex`), shared and per
    /// steward, in ledger order.
    public func preferences(person: String) async throws -> [MemorySummary] {
        let projection = try MemoryProjection(ledger: try facadeState().events)
        return projection.stewards.flatMap { projection.liveNotes(steward: $0) }
            .filter { $0.note.tags.contains("preference") && $0.note.tags.contains(person) }
            .sorted { $0.seq < $1.seq }
            .map { MemorySummary($0, retracted: false) }
    }

    /// Retracts a memory note (`memory.retracted`, with `person` as actor): it leaves
    /// `memory(steward:)`, `knowledge(steward:)`, and what later runs recall. Returns the note
    /// as retracted.
    @discardableResult
    public func retract(memory id: String, reason: String? = nil, by person: String = "local")
        async throws -> MemorySummary
    {
        let events = try facadeState().events
        let projection = try MemoryProjection(ledger: events)
        var steward: StewardID?
        for event in events where event.type.rawValue == MemoryEventType.added {
            guard let body = try? event.payload(as: MemoryAddedPayload.self),
                body.note.id.rawValue == id
            else { continue }
            steward = event.steward
        }
        guard let steward,
            let found = projection.allNotes(steward: steward).first(where: {
                $0.note.note.id.rawValue == id
            })
        else { throw WorkspaceError.notFound(id) }
        guard !found.retracted else { throw WorkspaceError.rejected("\(id) is already retracted") }
        let payload = MemoryRetractedPayload(
            note: found.note.note.id, reason: reason.flatMap { $0.isEmpty ? nil : $0 })
        _ = try await sink.append(
            RuntimeEventDraft(
                type: MemoryEventType.retracted, steward: steward, actor: .person(person),
                payload: try CanonicalJSON.decode(
                    JSONValue.self, from: try CanonicalJSON.encode(payload))))
        return MemorySummary(found.note, retracted: true)
    }

    // MARK: Routines

    /// A steward's routines, sorted by name.
    public func routines(steward: String) async throws -> [RoutineSummary] {
        let id = try await existing(steward).id
        return try RoutineLibrary(ledger: try facadeState().events).overview(steward: id)
            .map(RoutineSummary.init)
    }

    /// One routine version with its body; `nil` when the steward has no such version.
    public func routine(steward: String, name: String, version: String) async throws
        -> RoutineDetail?
    {
        let id = try await existing(steward).id
        let library = try RoutineLibrary(ledger: try facadeState().events)
        guard let found = library.version(steward: id, name: name, version: version) else {
            return nil
        }
        let live = library.live(steward: id, name: name)?.version
        return RoutineDetail(
            found, content: try? found.content(from: BlobStore(home: home)), live: live)
    }

    /// The body of one routine version, or `nil` if the version or its blob is missing.
    public func routineContent(steward: String, name: String, version: String) async throws
        -> String?
    {
        try await routine(steward: steward, name: name, version: version)?.content
    }

    /// A routine's proposals, promotions, and retirements in ledger order.
    public func routineHistory(steward: String, name: String) async throws
        -> [RoutineHistoryItem]
    {
        let id = try await existing(steward).id
        let events = try facadeState().events
        let times = Dictionary(
            events.map { (Int($0.seq), $0.at.date) }, uniquingKeysWith: { first, _ in first })
        return try RoutineLibrary(ledger: events).history(steward: id, name: name).map {
            RoutineHistoryItem(
                kind: $0.kind.rawValue, version: $0.version, seq: $0.seq,
                at: times[$0.seq] ?? Date(timeIntervalSince1970: 0))
        }
    }

    // MARK: Cases

    /// The expected result of one case in a casebook version, as canonical JSON, or `nil`
    /// when the casebook or the case is missing.
    public func caseExpected(casebook version: String, case caseID: String) async throws -> Data? {
        guard let book = try? await casebookSource.casebook(version: version),
            let item = book.cases.first(where: { $0.id.rawValue == caseID })
        else { return nil }
        return try CanonicalJSON.encode(item.expected)
    }
}

extension MemorySummary {
    init(_ live: LiveNote, retracted: Bool) {
        let note = live.note
        let author = note.provenance.author
        self.init(
            id: note.id.rawValue, steward: live.steward.rawValue, text: note.text, tags: note.tags,
            author: "\(author.kind.rawValue):\(author.id)", run: note.provenance.run?.rawValue,
            caseID: note.provenance.caseID?.rawValue, event: note.provenance.event?.rawValue,
            retracted: retracted, seq: live.seq)
    }
}

extension RoutineSummary {
    init(_ overview: RoutineOverview) {
        self.init(
            name: overview.name, language: overview.language.rawValue,
            liveVersion: overview.liveVersion, latestVersion: overview.latestVersion,
            versions: overview.versions, pending: overview.pending, summary: overview.summary)
    }
}

extension RoutineDetail {
    init(_ version: RoutineVersion, content: String?, live: String?) {
        let gate: GateStatus =
            version.version == live ? .live : version.promotedSeq == nil ? .pending : .superseded
        self.init(
            steward: version.steward.rawValue, name: version.name, version: version.version,
            language: version.language.rawValue, content: content, bytes: version.bytes,
            summary: version.summary, reason: version.reason, run: version.run?.rawValue,
            proposal: version.proposal?.rawValue, gate: gate, proposedSeq: version.proposedSeq,
            promotedSeq: version.promotedSeq)
    }
}
