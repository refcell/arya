import AryaCore
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

actor MemoryRecorder: EvalRecorder {
    var blobs: [String: Data] = [:]
    var events: [(type: String, steward: StewardID?, payload: JSONValue)] = []

    func putBlob(_ data: Data) async throws -> String {
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        blobs[key] = data
        return key
    }

    func append(type: String, steward: StewardID?, payload: JSONValue) async throws {
        events.append((type, steward, payload))
    }
}

@Test func parsesAndSortsCases() throws {
    let book = try Casebook.parse(name: "triage", data: try fixture("triage.jsonl"))
    #expect(book.cases.map(\.id.rawValue) == ["case-0001", "case-0002"])
    #expect(book.cases[1].context == .object([:]))
    #expect(book.version.count == 64)
}

@Test func versionIgnoresOrderAndFormatting() throws {
    let a = #"{"v":1,"id":"a","input":{"x":1},"expected":{"y":"p/q"}}"#
    let b = #"{"v":1,"id":"b","input":{},"expected":{}}"#
    let spaced = #"{ "expected": {"y": "p\/q"}, "id": "a", "input": {"x": 1}, "v": 1 }"#
    let one = try Casebook.parse(name: "n", data: Data("\(a)\n\(b)\n".utf8))
    let two = try Casebook.parse(name: "n", data: Data("\(b)\n\(spaced)".utf8))
    #expect(one.version == two.version)
    let changed = try Casebook.parse(
        name: "n", data: Data("\(b)\n\(a.replacingOccurrences(of: "1}", with: "2}"))".utf8))
    #expect(changed.version != one.version)
}

@Test func normalizedFormIsGolden() throws {
    let line = #"{"v":1,"id":"a","input":{"url":"a/b"},"expected":{}}"#
    let book = try Casebook.parse(name: "n", data: Data(line.utf8))
    let text = String(decoding: try book.normalizedData(), as: UTF8.self)
    #expect(text == #"{"context":{},"expected":{},"id":"a","input":{"url":"a/b"},"v":1}"# + "\n")
}

@Test func rejectsBadCasebooks() {
    let ok = #"{"v":1,"id":"a","input":{},"expected":{}}"#
    #expect(throws: CasebookError.invalidLine(line: 2, reason: "not a case object")) {
        try Casebook.parse(name: "n", data: Data("\(ok)\n{nope\n".utf8))
    }
    #expect(throws: CasebookError.duplicateID("a")) {
        try Casebook.parse(name: "n", data: Data("\(ok)\n\(ok)".utf8))
    }
    #expect(throws: CasebookError.unsupportedVersion(line: 1, version: 2)) {
        try Casebook.parse(
            name: "n", data: Data(ok.replacingOccurrences(of: "\"v\":1", with: "\"v\":2").utf8))
    }
    #expect(throws: CasebookError.invalidLine(line: 1, reason: "not a case object")) {
        try Casebook.parse(
            name: "n", data: Data(ok.replacingOccurrences(of: "\"a\"", with: "\"\"").utf8))
    }
    #expect(throws: CasebookError.empty) { try Casebook.parse(name: "n", data: Data("\n".utf8)) }
}

@Test func importRecordsBlobAndEvent() async throws {
    let recorder = MemoryRecorder()
    let (book, payload) = try await CasebookImporter(recorder: recorder)
        .importCasebook(
            name: "triage", data: try fixture("triage.jsonl"),
            steward: StewardID(unchecked: "st_triage"))
    #expect(payload.blob == book.version)
    #expect(payload.cases == 2)
    let blobs = await recorder.blobs
    #expect(blobs[book.version] == (try book.normalizedData()))
    let events = await recorder.events
    #expect(events.count == 1)
    #expect(events[0].type == "casebook.imported")
    #expect(events[0].steward?.rawValue == "st_triage")
    #expect(events[0].payload["version"] == .string(book.version))
}
