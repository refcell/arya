import AryaCore
import CryptoKit
import Foundation
import Testing

@testable import AryaLedger

private let resealKey = try! Curve25519.Signing.PrivateKey(
    rawRepresentation: Array(repeating: UInt8(9), count: 32))

private func text(_ value: String) -> EventDraft {
    EventDraft(type: "test.note", actor: .local, payload: ["text": .string(value)])
}

/// A home with clear history over small segments and a checkpoint, then encryption enabled
/// and one sealed event after it.
private func clearThenEncrypted(_ home: TempHome) throws -> (LedgerStore, CheckpointSigner) {
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 600)
    let signer = try CheckpointKeys(home: home.url).ensure(store: store) { resealKey }
    for index in 0..<12 { try store.append(text("clear \(index)")) }
    try Checkpoints(home: home.url).record(store: store, signer: signer)
    try HomeEncryption.enable(
        store: store, keys: MemoryHomeKeyStore(), key: try HomeKey(bytes: Array(0..<32)))
    try store.append(text("after"))
    return (store, signer)
}

@Test func resealingSealsEarlierPayloadsAndTheLedgerStillVerifies() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let (store, signer) = try clearThenEncrypted(home)
    let before = try LedgerReader(home: home.url).events()
    func liveText() throws -> String {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            .filter { $0.hasSuffix(".jsonl") }
            .map {
                try String(contentsOf: store.directory.appendingPathComponent($0), encoding: .utf8)
            }
            .joined()
    }
    #expect(try liveText().contains("clear 0"))

    let applied = try #require(try Reseal.apply(store: store, signer: signer, actor: .local))
    #expect(applied.sealed == 12)
    #expect(applied.checkpoints == 1)
    #expect(applied.previousHead == before.last?.hash)

    let after = try LedgerReader(home: home.url).events()
    // Same events, opened the same; only hashes (and re-signed checkpoints) changed.
    let notCheckpoint = { (event: Event) in event.type != .systemCheckpoint }
    #expect(
        after.dropLast().filter(notCheckpoint).map(\.payload)
            == before.filter(notCheckpoint).map(\.payload))
    #expect(after.dropLast().map(\.id) == before.map(\.id))
    #expect(after.last?.type == .systemLedgerResealed)
    #expect(try !liveText().contains("clear "))
    #expect(
        !FileManager.default.fileExists(
            atPath: home.url.appendingPathComponent("ledger.reseal").path))
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.ok, "\(verdict.report.text)")
    // The hash map ties the old chain to the new one.
    let map = try JSONParser.parse(Array(try store.blobs.get(applied.map)))
    guard case .array(let rows)? = map.objectValue?["map"] else {
        Issue.record("no map")
        return
    }
    // Every event from the first sealed one on changed hash; the key event before it did not.
    #expect(rows.count == before.count - 1)
    // A second run finds nothing in the clear.
    #expect(try Reseal.apply(store: store, signer: signer, actor: .local) == nil)
}

@Test func resealingRefusesAClearHomeAndACompactedOne() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 600)
    let signer = try CheckpointKeys(home: home.url).ensure(store: store) { resealKey }
    for index in 0..<12 { try store.append(text("clear \(index)")) }
    #expect(throws: ResealError.notEncrypted) {
        try Reseal.apply(store: store, signer: signer, actor: .local)
    }
    try Checkpoints(home: home.url).record(store: store, signer: signer)
    try store.compact(through: 6)
    try HomeEncryption.enable(
        store: store, keys: MemoryHomeKeyStore(), key: try HomeKey(bytes: Array(0..<32)))
    #expect(throws: ResealError.compacted) {
        try Reseal.apply(store: store, signer: signer, actor: .local)
    }
}
