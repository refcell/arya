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
        try LedgerReader(home: home.url, archive: false).events()
            == Array(before.drop { $0.seq < result.firstSeq })
    )
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.ok, "\(verdict.report.text)")
    #expect(verdict.firstSeq == result.firstSeq)
    #expect(try LedgerReader(home: home.url).events() == before)
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

/// Counts events and remembers the newest note text.
private struct Tally: LedgerProjection, Codable, Hashable {
    var count = 0
    var last = ""

    mutating func apply(_ event: Event) throws {
        count += 1
        if case .string(let text)? = event.payload.objectValue?["text"] { last = text }
    }
}

/// A compacted home whose checkpoint at the head carried a `tally` seed, plus one event after.
private func seededCompactedHome() throws -> (TempHome, LedgerStore, Int64) {
    let home = try TempHome()
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 600)
    let signer = try CheckpointKeys(home: home.url).ensure(store: store) { fixedKey(1) }
    for index in 0..<30 { try store.append(note("note \(index)")) }
    let caches = ProjectionCache(home: home.url)
    _ = try caches.current(Tally.self, name: "tally")
    let event = try Checkpoints(home: home.url).record(store: store, signer: signer, caches: caches)
    let checkpoint = try event.payload(as: SystemCheckpoint.self)
    #expect(checkpoint.projections["tally"] != nil)
    try store.append(note("after"))
    try store.compact(through: 20)
    return (home, store, checkpoint.through)
}

@Test func compactedLedgerRestoresAProjectionFromItsSeed() throws {
    let (home, _, through) = try seededCompactedHome()
    defer { home.cleanup() }
    let caches = ProjectionCache(home: home.url)
    let seedFile = home.url.appendingPathComponent("archive/seeds/\(through)/tally.json")
    #expect(FileManager.default.fileExists(atPath: seedFile.path))
    try FileManager.default.removeItem(at: caches.directory)
    try removeArchivedSegments(home)
    let restored = try caches.current(Tally.self, name: "tally")
    #expect(restored.value == Tally(count: 33, last: "after"))
    #expect(restored.seq == 33)
    // The restored cache is saved and keeps catching up normally.
    #expect(caches.load(Tally.self, name: "tally")?.seq == 33)
}

@Test func compactedLedgerWithoutAMatchingSeedReportsArchived() throws {
    let (home, _, through) = try seededCompactedHome()
    defer { home.cleanup() }
    let caches = ProjectionCache(home: home.url)
    try FileManager.default.removeItem(at: caches.directory)
    try removeArchivedSegments(home)
    #expect(throws: ProjectionError.archived("other")) {
        try caches.current(Tally.self, name: "other")
    }
    // A seed whose value changed no longer matches its checkpoint digest.
    let seedFile = home.url.appendingPathComponent("archive/seeds/\(through)/tally.json")
    let text = String(decoding: try Data(contentsOf: seedFile), as: UTF8.self)
    try Data(text.replacingOccurrences(of: "\"count\":31", with: "\"count\":99").utf8)
        .write(to: seedFile)
    #expect(throws: ProjectionError.archived("tally")) {
        try caches.current(Tally.self, name: "tally")
    }
}

/// Deletes the archived segments (not the seeds), as if the archive were moved off the machine.
private func removeArchivedSegments(_ home: TempHome) throws {
    let archive = home.url.appendingPathComponent("archive")
    for name in try FileManager.default.contentsOfDirectory(atPath: archive.path)
    where name.hasSuffix(".jsonl") {
        try FileManager.default.removeItem(at: archive.appendingPathComponent(name))
    }
}

@Test func historyReadsSeeArchivedSegmentsAndLiveReadsDoNot() throws {
    let (home, store) = try compactableHome()
    defer { home.cleanup() }
    let before = try LedgerReader(home: home.url).events()
    let result = try store.compact(through: 20)
    #expect(!result.archived.isEmpty)
    #expect(try LedgerReader(home: home.url).events() == before)
    #expect(try LedgerReader(home: home.url).events(from: 3).first?.seq == 3)
    #expect(try LedgerReader(home: home.url, archive: false).events().first?.seq == result.firstSeq)
    // A fresh cache rebuilds through the archive; no seed is needed.
    let caches = ProjectionCache(home: home.url)
    #expect(try caches.current(Tally.self, name: "tally").seq == before.last?.seq)
    #expect(try LedgerVerifier(home: home.url).verify().ok)
}

@Test func retentionArchivesOldSegmentsAndHistoryStillReadsThem() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 600)
    let signer = try CheckpointKeys(home: home.url).ensure(store: store) { fixedKey(1) }
    for index in 0..<30 { try store.append(note("note \(index)")) }
    try store.append(EventDraft(SystemRetentionSet(days: 1), actor: .human("local")))
    let before = try LedgerReader(home: home.url).events()
    let clock = Timestamp(millis: 1_767_225_600_000 + 400 * 86_400_000)
    let applied = try #require(
        try RetentionArchive.apply(store: store, signer: signer, now: clock, actor: .human("local"))
    )
    #expect(!applied.segments.isEmpty)
    let after = try LedgerReader(home: home.url).events()
    #expect(Array(after.prefix(before.count)) == before)
    #expect(after.last?.type == .systemRetentionApplied)
    #expect(
        try LedgerReader(home: home.url, archive: false).events().first?.seq == applied.through + 1)
    #expect(try LedgerVerifier(home: home.url).verify().ok)
    #expect(try LedgerVerifier(home: home.url).verifyArchive().ok)
    #expect(try RetentionPolicy.read(LedgerReader(home: home.url)).defaultDays == 1)
}
