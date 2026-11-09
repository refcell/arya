import AryaCore
import AryaRuntime
import CryptoKit
import Foundation
import Testing

@testable import AryaEval

func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

actor MemoryBlobs: EvalBlobStore {
    var blobs: [String: Data] = [:]

    func putBlob(_ data: Data) async throws -> String {
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        blobs[key] = data
        return key
    }

    func overwrite(_ hex: String, with data: Data) {
        blobs[hex] = data
    }

    func getBlob(_ hex: String) async throws -> Data {
        guard let data = blobs[hex] else { throw EvalError.unknownCasebook(hex) }
        return data
    }
}

@Test func parsesAndSortsCases() throws {
    let book = try Casebook.parse(name: "triage", data: try fixture("triage.jsonl"))
    #expect(book.cases.map(\.id.rawValue) == ["case-0001", "case-0002"])
    #expect(book.cases[1].context == CaseContext())
    #expect(book.cases[0].context.toolResults.first?.tool == "tracker.get")
    #expect(book.version.count == 64)
}

@Test func versionIgnoresOrderAndFormatting() throws {
    let a = #"{"v":1,"id":"a","input":{"text":"t/1"},"expected":{"y":1}}"#
    let b = #"{"v":1,"id":"b","input":{"text":"t2"},"expected":{}}"#
    let spaced = #"{ "expected": {"y": 1}, "id": "a", "input": {"text": "t\/1"}, "v": 1 }"#
    let one = try Casebook.parse(name: "n", data: Data("\(a)\n\(b)\n".utf8))
    let two = try Casebook.parse(name: "n", data: Data("\(b)\n\(spaced)".utf8))
    #expect(one.version == two.version)
    let edited = a.replacingOccurrences(of: "\"y\":1", with: "\"y\":2")
    let changed = try Casebook.parse(name: "n", data: Data("\(b)\n\(edited)".utf8))
    #expect(changed.version != one.version)
}

@Test func normalizedFormIsGolden() throws {
    let line = #"{"v":1,"id":"a","input":{"text":"see a/b"},"expected":{}}"#
    let book = try Casebook.parse(name: "n", data: Data(line.utf8))
    let text = String(decoding: try book.normalizedData(), as: UTF8.self)
    let golden =
        #"{"context":{"memory":[],"toolResults":[]},"expected":{},"id":"a","#
        + #""input":{"attachments":[],"kind":"case","text":"see a/b"},"v":1}"# + "\n"
    #expect(text == golden)
}

@Test func rejectsBadCasebooks() {
    let ok = #"{"v":1,"id":"a","input":{"text":"t"},"expected":{}}"#
    #expect(throws: CasebookError.invalidLine(line: 2, reason: "not a case object")) {
        try Casebook.parse(name: "n", data: Data("\(ok)\n{nope\n".utf8))
    }
    #expect(throws: CasebookError.duplicateID("a")) {
        try Casebook.parse(name: "n", data: Data("\(ok)\n\(ok)".utf8))
    }
    let v2 = ok.replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
    #expect(throws: CasebookError.unsupportedVersion(line: 1, version: 2)) {
        try Casebook.parse(name: "n", data: Data(v2.utf8))
    }
    let noID = ok.replacingOccurrences(of: "\"a\"", with: "\"\"")
    #expect(throws: CasebookError.invalidLine(line: 1, reason: "not a case object")) {
        try Casebook.parse(name: "n", data: Data(noID.utf8))
    }
    let blank = ok.replacingOccurrences(of: "\"t\"", with: "\" \"")
    #expect(throws: CasebookError.invalidLine(line: 1, reason: "input.text: must not be empty")) {
        try Casebook.parse(name: "n", data: Data(blank.utf8))
    }
    #expect(throws: CasebookError.empty) { try Casebook.parse(name: "n", data: Data("\n".utf8)) }
}

@Test func importRecordsBlobAndEvent() async throws {
    let blobs = MemoryBlobs()
    let sink = MemoryEventSink(ambient: .fixed())
    let (book, payload) = try await CasebookImporter(blobs: blobs, sink: sink)
        .importCasebook(
            name: "triage", data: try fixture("triage.jsonl"),
            steward: StewardID(unchecked: "st_triage"))
    #expect(payload.blob == book.version)
    #expect(payload.cases == 2)
    let stored = await blobs.blobs
    #expect(stored[book.version] == (try book.normalizedData()))
    let events = try await sink.events(from: 1)
    #expect(events.count == 1)
    #expect(events[0].type == "casebook.imported")
    #expect(events[0].draft.steward?.rawValue == "st_triage")
    #expect(events[0].draft.actor == .localUser)
    #expect(events[0].payload["version"] == .string(book.version))
}
