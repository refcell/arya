import AryaCore
import AryaLedger
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

private let steward = StewardID(unchecked: "st_triage")

@Test func projectsVersionsAndLatestPerName() async throws {
    let sink = MemoryEventSink(ambient: .fixed())
    let blobs = MemoryBlobs()
    let importer = CasebookImporter(blobs: blobs, sink: sink)
    let (first, _) = try await importer.importCasebook(
        name: "triage", data: try fixture("triage.jsonl"), steward: steward)
    let corrected = try first.correcting(
        CaseID(rawValue: "case-0001")!, expected: ["decisions": [["choice": "incident"]]])
    try await importer.record(
        corrected, steward: steward, actor: .person("person:alex"), correctedFrom: first.version)
    let other = #"{"v":1,"id":"x","input":{"text":"t"},"expected":{}}"#
    try await importer.importCasebook(name: "billing", data: Data(other.utf8), steward: steward)
    try await importer.importCasebook(
        name: "triage", data: try fixture("triage.jsonl"), steward: steward)

    let book = try CasebookBook(try await sink.events(from: 1))
    #expect(book.names.map(\.imported.name) == ["billing", "triage"])
    #expect(book.latest["triage"] == first.version)
    #expect(book.history("triage").map(\.imported.version) == [first.version, corrected.version])
    #expect(book.versions[corrected.version]?.actor == .person("person:alex"))

    let stored = StoredCasebooks(sink: sink, blobs: blobs)
    #expect(try await stored.casebook(version: corrected.version) == corrected)
    #expect(try await stored.latest(name: "triage") == first)
    await #expect(throws: EvalError.unknownCasebook("nope")) {
        try await stored.casebook(version: "nope")
    }
}

@Test func storedCasebooksWorkOnTheLedgerBlobStore() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-eval-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let blobs = BlobStore(home: home)
    let sink = MemoryEventSink(ambient: .fixed())
    let (book, payload) = try await CasebookImporter(blobs: blobs, sink: sink)
        .importCasebook(name: "triage", data: try fixture("triage.jsonl"), steward: steward)
    #expect(blobs.exists(payload.blob))
    #expect(
        try await StoredCasebooks(sink: sink, blobs: blobs).casebook(version: book.version) == book)
}

@Test func tamperedBlobIsRefused() async throws {
    let sink = MemoryEventSink(ambient: .fixed())
    let blobs = MemoryBlobs()
    let (book, payload) = try await CasebookImporter(blobs: blobs, sink: sink)
        .importCasebook(name: "triage", data: try fixture("triage.jsonl"), steward: steward)
    let one = #"{"v":1,"id":"x","input":{"text":"t"},"expected":{}}"#
    await blobs.overwrite(payload.blob, with: Data(one.utf8))
    await #expect(throws: EvalError.self) {
        try await StoredCasebooks(sink: sink, blobs: blobs).casebook(version: book.version)
    }
}
