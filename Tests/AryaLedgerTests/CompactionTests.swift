import AryaCore
import CryptoKit
import Foundation
import Testing

@testable import AryaLedger

private func fixedKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
    try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
}

/// A home with a recorded key, 30 notes over 600-byte segments, and optionally a checkpoint
/// at the head.
private func compactableHome(checkpoint: Bool = true) throws -> (TempHome, LedgerStore) {
    let home = try TempHome()
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 600)
    let signer = try CheckpointKeys(home: home.url).ensure(store: store) { fixedKey(1) }
    for index in 0..<30 { try store.append(note("note \(index)")) }
    if checkpoint { try Checkpoints(home: home.url).record(store: store, signer: signer) }
    return (home, store)
}

@Test func compactionArchivesCoveredSegmentsAndStaysVerifiable() throws {
    let (home, store) = try compactableHome()
    defer { home.cleanup() }
    let before = try LedgerReader(home: home.url).events()
    let result = try store.compact(through: 20)
    #expect(!result.archived.isEmpty)
    #expect(result.firstSeq > 1 && result.firstSeq <= 21)
    #expect(result.checkpoint == 32)
    let archived = try FileManager.default.contentsOfDirectory(
        atPath: store.archiveDirectory.path
    ).sorted()
    #expect(archived == result.archived)
    #expect(
        try LedgerReader(home: home.url).events() == Array(before.drop { $0.seq < result.firstSeq })
    )
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.ok, "\(verdict.report.text)")
    #expect(verdict.firstSeq == result.firstSeq)
    #expect(try LedgerVerifier(home: home.url).verifyArchive().ok)
    // Writing goes on, and compacting again with nothing newly covered is a no-op.
    try store.append(note("after"))
    #expect(try store.compact(through: 20).archived.isEmpty)
    #expect(try LedgerVerifier(home: home.url).verify().ok)
}

@Test func compactionRefusesWithoutACheckpointOrOnABrokenLedger() throws {
    let (home, store) = try compactableHome(checkpoint: false)
    defer { home.cleanup() }
    #expect(throws: CompactionError.noCheckpoint(20)) { try store.compact(through: 20) }
    let (broken, brokenStore) = try compactableHome()
    defer { broken.cleanup() }
    var bytes = try Data(contentsOf: broken.segment(2))
    bytes[bytes.count - 100] ^= 0x01
    try bytes.write(to: broken.segment(2))
    #expect(throws: CompactionError.self) { try brokenStore.compact(through: 20) }
    #expect(!FileManager.default.fileExists(atPath: brokenStore.archiveDirectory.path))
}

@Test func compactionRefusesToOverwriteTheArchive() throws {
    let (home, store) = try compactableHome()
    defer { home.cleanup() }
    try FileManager.default.createDirectory(
        at: store.archiveDirectory, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: store.archiveDirectory.appendingPathComponent("000001.jsonl"))
    #expect(throws: CompactionError.archiveConflict("000001.jsonl")) {
        try store.compact(through: 20)
    }
    #expect(FileManager.default.fileExists(atPath: home.segment(1).path))
}

@Test func verifyArchiveFindsMissingAndChangedSegments() throws {
    let (home, store) = try compactableHome()
    defer { home.cleanup() }
    #expect(try LedgerVerifier(home: home.url).verifyArchive().failure == .nothingAnchored)
    let result = try store.compact(through: 20)
    let verifier = LedgerVerifier(home: home.url)
    let ok = try verifier.verifyArchive()
    #expect(ok.checked == result.archived)
    #expect(
        ok.headline == "archive ok: \(result.archived.count) archived segments match the checkpoint"
    )
    let first = store.archiveDirectory.appendingPathComponent(result.archived[0])
    var bytes = try Data(contentsOf: first)
    bytes[10] ^= 0x01
    try bytes.write(to: first)
    #expect(try verifier.verifyArchive().failure == .digestMismatch(result.archived[0]))
    try FileManager.default.removeItem(at: first)
    let missing = try verifier.verifyArchive()
    #expect(missing.failure == .missing(result.archived[0]))
    #expect(missing.headline.hasPrefix("archive broken: \(result.archived[0]) is missing"))
    // The live ledger still verifies: the checkpoint vouches for what was archived.
    #expect(try verifier.verify().ok)
}
