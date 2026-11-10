import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

private let historySteward = StewardID(unchecked: "st_hist")

private let histCharter = Charter(
    id: historySteward, name: "History triage", outcome: "Every issue is triaged.",
    metric: Metric(name: "triaged", unit: "ratio", direction: .up), adapter: "fake")

private func item(_ id: String, _ input: String, _ choice: String, at: String) -> HistoryItem {
    HistoryItem(
        id: id, at: at, input: input, record: ["id": .string(id), "subject": .string(input)],
        actions: [HistoryAction(kind: "route", target: "inbox:\(id)", by: "person:sam")],
        choice: choice)
}

@Test func historyItemsReadFromExportsAndToolPages() throws {
    let export = """
        {"v":1,"history":[
          {"id":"MSG-1","at":"2026-09-01T08:00:00Z","input":"Charged twice","choice":"billing"},
          {"id":"MSG-2","input":"no time"},
          {"id":"MSG-3","at":"2026-09-02T08:00:00Z","input":"App crashes",
           "actions":[{"kind":"label","target":"inbox:MSG-3","by":"person:sam"}]}]}
        """
    let file = HistorySource.items(export: Data(export.utf8))
    #expect(file.items.map(\.id) == ["MSG-1", "MSG-3"])
    #expect(file.invalid == ["MSG-2: not a history item (needs id, at, input)"])
    #expect(HistorySource.items(export: Data("[]".utf8)).invalid.count == 1)

    let page = HistoryListResult(
        items: [item("A", "x", "bug", at: "2026-09-01T00:00:00Z")], next: "50")
    let structured: JSONValue = ["structuredContent": try CanonicalJSON.jsonValue(page)]
    let read = HistorySource.page(toolResult: structured)
    #expect(read.items.map(\.id) == ["A"])
    #expect(read.next == "50")
    let text: JSONValue = [
        "content": [["type": "text", "text": .string(try CanonicalJSON.string(page))]]
    ]
    #expect(HistorySource.page(toolResult: text).items.map(\.id) == ["A"])
    #expect(HistorySource.page(toolResult: ["nothing": true]).invalid.count == 1)
}

@Test func historyCaseCarriesWhatThePersonDidAndTheRecord() throws {
    let rerouted = HistoryItem(
        id: "MSG-4", at: "2026-09-03T11:00:00Z", input: "New message MSG-4: Not shipped",
        record: ["id": "MSG-4", "subject": "Not shipped"],
        actions: [
            HistoryAction(kind: "route", target: "inbox:MSG-4", by: "person:sam"),
            HistoryAction(kind: "route", target: "inbox:MSG-4", by: "person:alex"),
            HistoryAction(kind: "label", target: "inbox:MSG-4", by: "person:alex"),
        ],
        choice: "shipping", outcome: HistoryOutcome(status: "reopened", note: "Rerouted."))
    let plan = try HistoryImporter.plan(
        [rerouted], into: nil, source: "inbox.history", binding: "inbox", limit: 10, invalid: [])
    let made = try #require(plan.cases.first)
    #expect(made.id.rawValue == "hist-MSG-4")
    #expect(
        made.expected == [
            "decisions": [["choice": "shipping"]],
            "actions": [
                ["kind": "route", "target": "inbox:MSG-4"],
                ["kind": "label", "target": "inbox:MSG-4"],
            ],
        ])
    #expect(made.context.toolResults.map(\.tool) == ["inbox.get"])
    #expect(made.context.toolResults.first?.input == ["id": "MSG-4"])
    #expect(
        made.source
            == "history inbox.history item MSG-4 by person:sam at 2026-09-03T11:00:00Z, "
            + "reopened: Rerouted.")
    let nobody = HistoryItem(id: "MSG-5", at: "2026-09-04T00:00:00Z", input: "Hello")
    #expect(
        try HistoryImporter.plan([nobody], into: nil, source: "f", limit: 10, invalid: []).invalid
            == ["MSG-5: nobody acted on it"])
}

@Test func historyImportDedupesCapsAndRecordsProvenance() async throws {
    let ambient = Ambient.fixed(stepMillis: 2, seed: 91)
    let sink = MemoryEventSink(ambient: ambient)
    let blobs = MemoryBlobs()
    let existing = try Casebook(
        name: "triage",
        cases: [
            Case(
                id: CaseID(rawValue: "case-0001")!, input: CaseInput(text: "Charged  TWICE"),
                expected: ["decisions": [["choice": "billing"]]])
        ])
    let importer = HistoryImporter(sink: sink, blobs: blobs)
    let items = [
        item("MSG-1", "charged twice", "billing", at: "2026-10-01T00:00:00Z"),
        item("MSG-2", "App crashes", "bug", at: "2026-10-03T00:00:00Z"),
        item("MSG-3", "Where is the report?", "how-to", at: "2026-10-02T00:00:00Z"),
        item("MSG-4", "Old one", "bug", at: "2026-09-01T00:00:00Z"),
        item("", "no id", "bug", at: "2026-10-04T00:00:00Z"),
        HistoryItem(id: "MSG-5", at: "2026-10-05T00:00:00Z", input: "Nothing done"),
        item("MSG 6", "bad id", "bug", at: "2026-10-06T00:00:00Z"),
    ]
    let result = try await importer.importHistory(
        items, invalid: ["MSG-9: not a history item (needs id, at, input)"], into: existing,
        name: "triage", steward: historySteward, source: "inbox.history", binding: "inbox",
        limit: 2)
    // Newest first, capped at 2: MSG-2 then MSG-3; MSG-4 is over the cap.
    #expect(result.added.map(\.rawValue) == ["hist-MSG-2", "hist-MSG-3"])
    #expect(result.duplicates == ["MSG-1"])
    #expect(result.overCap == 1)
    #expect(
        result.invalid == [
            "MSG-9: not a history item (needs id, at, input)",
            "MSG 6: id has characters a case id cannot hold", "MSG-5: nobody acted on it",
            "?: missing id",
        ])
    #expect(
        result.summary
            == "Added 2 cases from inbox.history; 1 already in the casebook, 4 invalid, "
            + "1 over the cap of 2.")
    let grown = try #require(result.casebook)
    #expect(grown.cases.count == 3)
    let added = try #require(grown.cases.first { $0.id.rawValue == "hist-MSG-2" })
    #expect(
        added.expected
            == [
                "decisions": [["choice": "bug"]],
                "actions": [["kind": "route", "target": "inbox:MSG-2"]],
            ])
    #expect(
        added.source == "history inbox.history item MSG-2 by person:sam at 2026-10-03T00:00:00Z")
    let stored = try await StoredCasebooks(sink: sink, blobs: blobs).latest(name: "triage")
    #expect(stored == grown)

    // A second import adds what the cap held back; a third adds nothing and records nothing.
    let again = try await importer.importHistory(
        items, into: grown, name: "triage", steward: historySteward, source: "inbox.history",
        limit: 2)
    #expect(again.added.map(\.rawValue) == ["hist-MSG-4"])
    let third = try await importer.importHistory(
        items, into: try #require(again.casebook), name: "triage", steward: historySteward,
        source: "inbox.history", limit: 2)
    #expect(third.casebook == nil)
    #expect(
        third.summary
            == "Added 0 cases from inbox.history; 4 already in the casebook, 3 invalid.")
}

@Test func reviewQueueOrdersCasesAndCountsProgress() async throws {
    let ambient = Ambient.fixed(stepMillis: 2, seed: 92)
    let sink = MemoryEventSink(ambient: ambient)
    let blobs = MemoryBlobs()
    let casebooks = StoredCasebooks(sink: sink, blobs: blobs)
    let line = { (id: String, choice: String) in
        #"{"v":1,"id":"\#(id)","input":{"text":"\#(id)"},"#
            + #""expected":{"decisions":[{"choice":"\#(choice)"}]}}"#
    }
    let data = [line("c1", "bug"), line("c2", "bug"), line("c3", "bug")].joined(separator: "\n")
    let (book, _) = try await CasebookImporter(blobs: blobs, sink: sink)
        .importCasebook(name: "triage", data: Data(data.utf8), steward: historySteward)
    let queue = ReviewQueue(sink: sink, casebooks: casebooks)

    // Before any rehearsal: everything pending, in casebook order.
    let fresh = try #require(try await queue.view(steward: historySteward))
    #expect(fresh.items.map(\.wouldHave) == Array(repeating: "Not rehearsed yet.", count: 3))
    #expect(fresh.progressText == "0 of 3 reviewed")
    #expect(fresh.next?.caseID == "c1")

    // The steward answers bug for c1 and c3, feature for c2: c2 disagrees and comes first.
    let rehearser = CasebookRehearser(
        runner: ScriptedRunner(
            answers: [
                "c1": ["decisions": [["choice": "bug"]]],
                "c2": ["decisions": [["choice": "feature"]]],
                "c3": ["decisions": [["choice": "bug"]]],
            ]),
        casebooks: casebooks, sink: sink, ambient: ambient,
        scorer: ExactScorer(fields: ["decisions.choice"]))
    _ = try await rehearser.rehearse(
        RehearsalRequest(steward: historySteward, charterVersion: 1, casebookVersion: book.version),
        charter: histCharter)
    let rehearsed = try #require(try await queue.view(steward: historySteward))
    #expect(rehearsed.items.map(\.caseID) == ["c2", "c1", "c3"])
    #expect(rehearsed.items[0].matches == false)
    #expect(rehearsed.items[0].difference.contains("expected bug"))
    #expect(rehearsed.progressText == "0 of 3 reviewed · 2 of 3 match what people did")

    // Agree, skip, and correct: corrections count as reviewed.
    try await queue.record(
        .agreed, caseID: CaseID(rawValue: "c1")!, casebook: book, steward: historySteward,
        person: "person:alex")
    try await queue.record(
        .skipped, caseID: CaseID(rawValue: "c3")!, casebook: book, steward: historySteward,
        person: "person:alex")
    _ = try await Corrector(sink: sink, blobs: blobs, ambient: ambient).correct(
        CaseCorrection(
            caseID: CaseID(rawValue: "c2")!, text: "Feature.",
            expected: ["decisions": [["choice": "feature"]]]),
        in: book, steward: historySteward, person: "person:alex")
    let done = try #require(try await queue.view(steward: historySteward))
    #expect(done.reviewed == 3 && done.agreed == 1 && done.skipped == 1 && done.corrected == 1)
    #expect(done.next == nil)
    #expect(done.progressText.hasPrefix("3 of 3 reviewed"))
    await #expect(throws: EvalError.unknownCase(CaseID(rawValue: "nope")!)) {
        try await queue.record(
            .agreed, caseID: CaseID(rawValue: "nope")!, casebook: book, steward: historySteward,
            person: "person:alex")
    }
}
