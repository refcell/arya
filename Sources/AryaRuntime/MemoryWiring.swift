import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory

// Memory and routines around a run: the snapshot and live routine versions `run.started`
// records and the instructions show, and `memory.added` for the notes a live run proposes.

extension MemoryEventRecord {
    /// The record the memory projections read from a runtime event.
    init(_ event: RuntimeEvent) throws {
        self.init(
            seq: event.seq, id: event.id, steward: event.draft.steward, run: event.draft.run,
            type: event.type, payload: try CanonicalJSON.encode(event.payload))
    }
}

extension RuntimeEventDraft {
    /// The runtime form of a ledger draft (for drafts other modules build).
    public init(_ draft: EventDraft) {
        self.init(
            type: draft.type.rawValue, steward: draft.steward, run: draft.run,
            actor: RuntimeActor(draft.actor), payload: draft.payload)
    }
}

/// Where memory notes live: under one steward, or shared by every steward.
public enum MemoryScope {
    /// The reserved scope whose notes every steward recalls. It is never a real steward.
    public static let shared = StewardID(unchecked: "st_shared")
    /// How many shared notes a run recalls at most, after its own.
    public static let maxSharedNotes = 4
}

/// Memory and routine projections over runtime events.
struct MemoryView {
    var memory: MemoryProjection
    var routines: RoutineLibrary

    init(_ events: [RuntimeEvent]) throws {
        self.init()
        for event in events { try apply(event) }
    }

    /// An empty view.
    init() {
        memory = MemoryProjection()
        routines = RoutineLibrary()
    }

    /// Folds one event.
    mutating func apply(_ event: RuntimeEvent) throws {
        if event.type.hasPrefix("memory.") {
            try memory.apply(try MemoryEventRecord(event))
        } else if event.type.hasPrefix("routine.") {
            try routines.apply(try MemoryEventRecord(event))
        }
    }

    /// The memory context of a run of `steward` on `input`, with `candidate` in place of the
    /// live version of its name when given (an unknown candidate version leaves the live set).
    func context(
        steward: StewardID, input: String, caseID: CaseID?, candidate: CandidateRoutine? = nil,
        people: [String] = []
    ) -> RunMemoryContext {
        var context = RunPreparation.context(
            steward: steward, inputText: input, caseID: caseID, memory: memory,
            routines: routines)
        if let candidate,
            let found = routines.version(
                steward: steward, name: candidate.name, version: candidate.version)
        {
            context.routines = (context.routines.filter { $0.name != candidate.name } + [found])
                .sorted { $0.name < $1.name }
            context.routineVersions[candidate.name] = candidate.version
        }
        guard steward != MemoryScope.shared else { return context }
        let query = MemoryQuery.forRun(
            inputText: input, caseID: caseID, knownTags: memory.tags(steward: MemoryScope.shared),
            maxNotes: MemoryScope.maxSharedNotes)
        let own = Set(context.notes.map(\.note.id))
        let shared = memory.retrieve(steward: MemoryScope.shared, query: query)
            .filter { !own.contains($0.note.id) }
        if !shared.isEmpty {
            context.notes += shared
            context.snapshot = MemorySnapshot(notes: context.notes.map(\.note.id))
        }
        PersonMemory.recall(people, steward: steward, memory: memory, into: &context)
        return context
    }
}

/// Memory about a person (decision 0061): live notes, the steward's own or shared, tagged
/// `person:<binding id>`: preferences a person states and corrections a person sends. A run
/// recalls them for each person it acts for: the sender of a message input and each person
/// binding its input names.
public enum PersonMemory {
    /// Most person notes a run recalls, after its own and shared notes.
    public static let maxNotes = 6

    /// The memory tag of person binding `id`.
    public static func tag(_ id: String) -> String { "person:" + id }

    /// The person ids a run of `charter` on `input` acts for: the message sender, each person
    /// binding named in the input text (in charter order), then each other `person:<id>` the
    /// text names, without repeats.
    public static func people(in input: RunInput, charter: Charter) -> [String] {
        var out: [String] = []
        for attachment in input.attachments {
            if let from = attachment["from"]?.stringValue, charter.binding(from)?.kind == .person {
                out.append(from)
            }
        }
        let words = Set(
            input.text.lowercased().split { !($0.isLetter || $0.isNumber || "_-:".contains($0)) }
                .map(String.init))
        for binding in charter.bindings where binding.kind == .person {
            let id = binding.id.lowercased()
            if words.contains(id) || words.contains(tag(id)), !out.contains(binding.id) {
                out.append(binding.id)
            }
        }
        // An explicit `person:<id>` counts even without a binding on this steward.
        for word in words.sorted() where word.hasPrefix("person:") && word.count > 7 {
            let id = String(word.dropFirst(7))
            if !out.contains(where: { $0.lowercased() == id }) { out.append(id) }
        }
        return out
    }

    /// Drops notes about anyone not in `people`, then adds `people`'s notes not already in
    /// `context`, newest first, up to `maxNotes`.
    static func recall(
        _ people: [String], steward: StewardID, memory: MemoryProjection,
        into context: inout RunMemoryContext
    ) {
        let tags = Set(people.map { tag($0.lowercased()) })
        // A note about someone else stays out of this run, wherever retrieval found it.
        let before = context.notes.count
        context.notes.removeAll { note in
            let about = note.note.tags.filter { $0.hasPrefix("person:") }
            return !about.isEmpty && tags.isDisjoint(with: about)
        }
        var changed = context.notes.count != before
        defer {
            if changed { context.snapshot = MemorySnapshot(notes: context.notes.map(\.note.id)) }
        }
        guard !people.isEmpty else { return }
        var have = Set(context.notes.map(\.note.id))
        let candidates =
            (memory.liveNotes(steward: steward)
            + memory.liveNotes(steward: MemoryScope.shared))
            .filter { !tags.isDisjoint(with: $0.note.tags) }
            .sorted { $0.seq > $1.seq }
        var added = 0
        for note in candidates where added < maxNotes && have.insert(note.note.id).inserted {
            context.notes.append(note)
            added += 1
        }
        if added > 0 { changed = true }
    }
}

extension InstructionInputs {
    /// Inputs for `charter` with the notes and routines of `context`.
    init(charter: Charter, context: RunMemoryContext, plan: [PlanItem] = []) {
        self.init(charter: charter)
        self.plan = plan
        memory = context.notes.map { live in
            // A note about a person says whom it is about (decision 0061).
            let about = live.note.tags.filter { $0.hasPrefix("person:") }
            let text =
                about.isEmpty
                ? live.note.text : "(\(about.joined(separator: ", "))) \(live.note.text)"
            return InstructionNote(id: live.note.id.rawValue, text: text)
        }
        routines = context.routines.map {
            InstructionRoutine(name: $0.name, version: $0.version, summary: $0.summary)
        }
    }
}
