import AryaCore
import AryaLedger
import AryaRuntime

/// Turns a recorded run into a case: its input, the tool results it saw (served back in
/// rehearsal), and what it did, so a live run can be corrected or rehearsed again.
public enum RunCases {
    /// The case id for a run that is not already a case: `run-<run id>`.
    public static func caseID(for run: RunID) throws -> CaseID {
        guard let id = CaseID(rawValue: "run-\(run.rawValue)") else {
            throw EvalError.unknownRun(run)
        }
        return id
    }

    /// The run as a case. `expected` defaults to what the run did (`did(_:run:)`).
    public static func makeCase(
        _ events: [RuntimeEvent], run: RunID, expected: JSONValue? = nil
    ) throws -> Case {
        guard
            let started = events.first(where: {
                $0.draft.run == run && $0.type == RunEventType.started
            })
        else { throw EvalError.unknownRun(run) }
        let body = try EvalPayload.decode(RunStarted.self, started.payload)
        if let caseID = body.caseID, body.rehearsal != nil {
            // A rehearsal run is already a case; keep its id so a correction updates it.
            return Case(
                id: caseID, input: CaseInput(text: body.input.text),
                context: CaseContext(toolResults: try ToolRecordings.from(events, run: run)),
                expected: try expected ?? did(events, run: run), source: "run \(run.rawValue)")
        }
        // The plan the steward had when the run started, so rehearsing the case shows it again.
        let before = events.filter { $0.seq < started.seq }
        let plan = try started.draft.steward.flatMap { try PlanBook(before).plans[$0] } ?? []
        return Case(
            id: try caseID(for: run),
            input: CaseInput(text: body.input.text, attachments: body.input.attachments ?? []),
            context: CaseContext(
                toolResults: try ToolRecordings.from(events, run: run),
                plan: try plan.map { try CanonicalJSON.jsonValue($0) }),
            expected: try expected ?? did(events, run: run), source: "run \(run.rawValue)")
    }

    /// What a run did, in the shape of a case's expected result: its decisions' choices and
    /// its proposed actions' kinds and targets.
    public static func did(_ events: [RuntimeEvent], run: RunID) throws -> JSONValue {
        var decisions: [JSONValue] = []
        var actions: [JSONValue] = []
        for event in events where event.draft.run == run {
            switch event.type {
            case RunEventType.decision:
                let body = try EvalPayload.decode(RunDecision.self, event.payload)
                decisions.append(["choice": .string(body.decision.choice)])
            case ActionEventType.proposed:
                let body = try EvalPayload.decode(ActionProposed.self, event.payload)
                var action: [String: JSONValue] = ["kind": .string(body.action.kind)]
                if let target = body.action.target { action["target"] = .string(target) }
                actions.append(.object(action))
            default:
                continue
            }
        }
        return ["decisions": .array(decisions), "actions": .array(actions)]
    }
}

extension Casebook {
    /// The casebook with `item` added, or replacing the case with the same id.
    public func upserting(_ item: Case) throws -> Casebook {
        try Casebook(name: name, cases: cases.filter { $0.id != item.id } + [item])
    }
}

extension Corrector {
    /// The facade's entry point: corrects what `run` did to `expected`. Finds the run's steward
    /// and that steward's newest casebook (or starts one named `corrections`), then corrects as
    /// `correct(run:expected:note:in:steward:person:)`.
    public func correct(
        run: RunID, expected: JSONValue, note: String? = nil, person: String = "local"
    ) async throws -> CorrectionOutcome {
        let events = try await sink.events(from: 1)
        guard
            let steward = events.first(where: {
                $0.draft.run == run && $0.type == RunEventType.started
            })?.draft.steward
        else { throw EvalError.unknownRun(run) }
        let newest = try CasebookBook(events).versions.values
            .filter { $0.steward == steward }
            .max { $0.seq < $1.seq }
        var book = try Casebook(name: "corrections", cases: [])
        if let newest {
            book = try await StoredCasebooks(sink: sink, blobs: blobs).casebook(
                version: newest.imported.version)
        }
        return try await correct(
            run: run, expected: expected, note: note ?? "Corrected what run \(run.rawValue) did.",
            in: book, steward: steward, person: person)
    }

    /// Corrects what a run did (the in-app correction on a run thread): the run becomes a case
    /// of `book` with `expected` (added, or updating the case a rehearsal run came from), a new
    /// casebook version is recorded, then `case.corrected` and the memory note as `correct`.
    /// Rehearsing the new version reflects the correction.
    public func correct(
        run: RunID, expected: JSONValue, note: String, in book: Casebook, steward: StewardID,
        person: String
    ) async throws -> CorrectionOutcome {
        let events = try await sink.events(from: 1)
        let item = try RunCases.makeCase(events, run: run, expected: expected)
        var base = book
        if !book.cases.contains(where: { $0.id == item.id }) {
            base = try book.upserting(item)
            try await CasebookImporter(blobs: blobs, sink: sink).record(
                base, steward: steward, actor: .person(person), correctedFrom: book.version)
        }
        var outcome = try await correct(
            CaseCorrection(caseID: item.id, text: note, expected: expected, run: run), in: base,
            steward: steward, person: person)
        if outcome.casebook == nil, base.version != book.version { outcome.casebook = base }
        return outcome
    }
}
