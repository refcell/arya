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

/// Memory and routine projections over runtime events.
struct MemoryView {
    var memory: MemoryProjection
    var routines: RoutineLibrary

    init(_ events: [RuntimeEvent]) throws {
        let records = try events.filter {
            $0.type.hasPrefix("memory.") || $0.type.hasPrefix("routine.")
        }.map(MemoryEventRecord.init)
        memory = try MemoryProjection(events: records.filter { $0.type.hasPrefix("memory.") })
        routines = try RoutineLibrary(events: records.filter { $0.type.hasPrefix("routine.") })
    }

    /// The memory context of a run of `steward` on `input`.
    func context(steward: StewardID, input: String, caseID: CaseID?) -> RunMemoryContext {
        RunPreparation.context(
            steward: steward, inputText: input, caseID: caseID, memory: memory,
            routines: routines)
    }
}

extension InstructionInputs {
    /// Inputs for `charter` with the notes and routines of `context`.
    init(charter: Charter, context: RunMemoryContext) {
        self.init(charter: charter)
        memory = context.notes.map { InstructionNote(id: $0.note.id.rawValue, text: $0.note.text) }
        routines = context.routines.map {
            InstructionRoutine(name: $0.name, version: $0.version, summary: $0.summary)
        }
    }
}
