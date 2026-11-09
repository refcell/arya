import AryaCore
import Foundation
import Testing

@testable import AryaLedger

/// Marks the test bundle so the test can find `AryaLedgerWriter` built next to it.
private final class BundleMarker {}

private let writerPath = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("AryaLedgerWriter").path

private func spawnWriter(home: URL, name: String, count: Int, seed: Int) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: writerPath)
    process.arguments = [home.path, name, String(count), String(seed)]
    process.environment = ["PATH": "/usr/bin:/bin"]
    try process.run()
    return process
}

@Test(.timeLimit(.minutes(1)))
func twoProcessesAndThisOneAppendWithoutLossOrInterleaving() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let perWriter = 150
    let children = try ["a", "b"].enumerated().map { index, name in
        try spawnWriter(home: home.url, name: name, count: perWriter, seed: index + 1)
    }
    let store = try LedgerStore(home: home.url, ambient: .fixed(seed: 9), segmentLimitBytes: 4096)
    for n in 1...perWriter {
        try store.append(
            EventDraft(
                type: "test.note", actor: .local, payload: ["writer": "p", "n": .int(Int64(n))]))
    }
    for child in children {
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
    }

    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.ok, "\(String(describing: verdict.failure))")
    let events = try LedgerReader(home: home.url).events()
    let notes = events.filter { $0.type == "test.note" }
    #expect(notes.count == 3 * perWriter)
    #expect(events.allSatisfy { $0.type == "test.note" }, "no repairs were needed")
    for writer in ["a", "b", "p"] {
        let numbers = notes.filter { $0.payload["writer"] == .string(writer) }
            .compactMap { $0.payload["n"]?.intValue }
        #expect(numbers == Array(1...Int64(perWriter)), "writer \(writer) lost or reordered")
    }
    #expect(try store.segments().count > 1)
}
