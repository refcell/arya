import AryaCore
import Foundation
import Testing

@testable import AryaLedger

/// Reads `Fixtures/<name>` next to this file.
func fixture(_ name: String) throws -> Data {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return try Data(contentsOf: dir.appendingPathComponent("Fixtures").appendingPathComponent(name))
}

/// The fixture as a string with one trailing newline removed.
func fixtureText(_ name: String) throws -> String {
    var text = String(decoding: try fixture(name), as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
}

let triage = StewardID(rawValue: "st_triage")!

/// A fresh temporary home directory, removed by the caller with `cleanup()`.
struct TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-ledger-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }

    func segment(_ number: Int) -> URL {
        url.appendingPathComponent("ledger").appendingPathComponent(Segment.name(number))
    }

    func lines(_ number: Int) throws -> [String] {
        let text = String(decoding: try Data(contentsOf: segment(number)), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

func note(_ text: String) -> EventDraft {
    EventDraft(type: "test.note", actor: .local, payload: ["text": .string(text)])
}
