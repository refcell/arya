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
