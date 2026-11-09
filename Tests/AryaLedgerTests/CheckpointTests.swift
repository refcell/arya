import AryaCore
import CryptoKit
import Foundation
import Testing

@testable import AryaLedger

private func fixedKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
    try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
}

/// A home with a recorded key and 30 notes over 600-byte segments.
private func signedHome() throws -> (TempHome, LedgerStore, CheckpointSigner) {
    let home = try TempHome()
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 600)
    let signer = try CheckpointKeys(home: home.url).ensure(store: store) { fixedKey(1) }
    for index in 0..<30 { try store.append(note("note \(index)")) }
    return (home, store, signer)
}

/// Appends `payload` re-signed by `signer`, as a forger with the key would.
private func appendSigned(
    _ payload: SystemCheckpoint, by signer: CheckpointSigner, to store: LedgerStore
) throws -> Event {
    var payload = payload
    payload.signature = try signer.sign(payload.signingBytes())
    return try store.append(EventDraft(payload, actor: .system))
}

@Test func recordedCheckpointsVerifyAndAreDeterministic() throws {
    let (home, store, signer) = try signedHome()
    defer { home.cleanup() }
    let checkpoints = Checkpoints(home: home.url)
    let built = try checkpoints.build(through: 20, signer: signer)
    #expect(
        try checkpoints.build(through: 20, signer: signer).signingBytes() == built.signingBytes())
    #expect(built.head == (try LedgerReader(home: home.url).events()[19].hash))
    #expect(built.keys == [signer.id: signer.publicKey.rawRepresentation.base64EncodedString()])
    #expect(!built.segments.isEmpty && built.segments.allSatisfy { $0.last <= 20 })
    #expect(zip(built.segments, built.segments.dropFirst()).allSatisfy { $0.last + 1 == $1.first })
    let event = try checkpoints.record(store: store, through: 20, signer: signer)
    #expect(event.type == .systemCheckpoint)
    #expect(
        try checkpoints.check(
            event.payload(as: SystemCheckpoint.self),
            ring: KeyRing.read(
                LedgerReader(home: home.url))) == nil)
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.ok, "\(verdict.report.text)")
    #expect(verdict.events == 32)
}

@Test func recordRefusesAnUnrecordedKey() throws {
    let (home, store, _) = try signedHome()
    defer { home.cleanup() }
    #expect(throws: CheckpointError.keyNotRecorded) {
        try Checkpoints(home: home.url).record(store: store, signer: CheckpointSigner(fixedKey(2)))
    }
    #expect(throws: CheckpointError.outOfRange(99)) {
        try Checkpoints(home: home.url).build(through: 99, signer: CheckpointSigner(fixedKey(1)))
    }
}

@Test func verifyRejectsBadCheckpoints() throws {
    let cases: [(String, (inout SystemCheckpoint) -> Void, CheckpointSigner?, CheckpointProblem)] =
        [
            ("unknown key", { _ in }, CheckpointSigner(fixedKey(9)), .unknownKey("")),
            ("head", { $0.head = String(repeating: "0", count: 64) }, nil, .headMismatch),
            (
                "segment", { $0.segments[0].sha256 = String(repeating: "1", count: 64) }, nil,
                .segmentMismatch("000001.jsonl")
            ),
            ("events", { $0.events = 3 }, nil, .malformed),
        ]
    for (name, mutate, forger, expected) in cases {
        let (home, store, signer) = try signedHome()
        defer { home.cleanup() }
        var payload = try Checkpoints(home: home.url).build(through: 20, signer: forger ?? signer)
        mutate(&payload)
        let event = try appendSigned(payload, by: forger ?? signer, to: store)
        let verdict = try LedgerVerifier(home: home.url).verify()
        #expect(verdict.firstBadSeq == event.seq, "\(name)")
        guard case .badCheckpoint(_, let problem)? = verdict.failure?.issue else {
            Issue.record("\(name): \(verdict.report.text)")
            continue
        }
        if case .unknownKey = expected {
            #expect(problem == .unknownKey(CheckpointSigner(fixedKey(9)).id), "\(name)")
        } else {
            #expect(problem == expected, "\(name)")
        }
    }
    // A tampered signature.
    let (home, store, signer) = try signedHome()
    defer { home.cleanup() }
    var payload = try Checkpoints(home: home.url).build(through: 20, signer: signer)
    payload.through = 19
    payload.events = 19
    try store.append(EventDraft(payload, actor: .system))
    #expect(
        try LedgerVerifier(home: home.url).verify().failure?.issue
            == .badCheckpoint(seq: 32, .badSignature))
}

/// Moves the segments wholly at or before `through` out of `ledger/`, as compaction will.
private func archive(_ home: TempHome, through: Int64) throws -> Int64 {
    let reader = LedgerReader(home: home.url)
    var cut: Int64 = 0
    for segment in try reader.existingSegments().dropLast() {
        guard let last = try reader.lastEvent(of: segment), last.seq <= through else { break }
        let dir = home.url.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: segment.url, to: dir.appendingPathComponent(segment.name))
        cut = last.seq
    }
    return cut
}

@Test func compactedLedgerVerifiesOnlyWithItsAnchor() throws {
    let (home, store, signer) = try signedHome()
    defer { home.cleanup() }
    let segments = try Checkpoints(home: home.url).build(through: 20, signer: signer).segments
    let through = try #require(segments.last?.last)
    try Checkpoints(home: home.url).record(store: store, through: through, signer: signer)
    try store.append(note("after"))
    #expect(try archive(home, through: through) == through)
    // The key's `system.key.added` was archived; the checkpoint carries the key.
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.ok, "\(verdict.report.text)")
    #expect(verdict.firstSeq == through + 1)
    #expect(try Checkpoints(home: home.url).trustedRing().keys[signer.id] != nil)
    // A second checkpoint on the compacted ledger still records and verifies.
    try Checkpoints(home: home.url).record(store: store, signer: signer)
    #expect(try LedgerVerifier(home: home.url).verify().ok)
}

@Test func compactedLedgerWithoutACheckpointIsUnanchored() throws {
    let (home, _, _) = try signedHome()
    defer { home.cleanup() }
    let through = try archive(home, through: 20)
    #expect(through > 0)
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.failure?.issue == .unanchored(first: through + 1))
    #expect(verdict.firstBadSeq == through + 1)
    #expect(verdict.report.headline.hasPrefix("ledger unanchored: starts at seq \(through + 1)"))
}
