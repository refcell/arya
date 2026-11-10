import AryaCore
import CryptoKit
import Foundation
import Testing

@testable import AryaLedger

private let auditKey = try! Curve25519.Signing.PrivateKey(
    rawRepresentation: Array(repeating: UInt8(5), count: 32))

private func stewardEvent(_ steward: StewardID, _ text: String) -> EventDraft {
    EventDraft(
        type: "test.note", actor: .local, steward: steward, payload: ["text": .string(text)])
}

/// A home with two stewards' events and a recorded checkpoint key.
private func auditedHome(_ home: TempHome) throws -> (LedgerStore, CheckpointSigner) {
    let store = try LedgerStore(home: home.url, ambient: .fixed(seed: 3))
    let signer = try CheckpointKeys(home: home.url).ensure(store: store) { auditKey }
    let other = StewardID(rawValue: "st_other")!
    try store.append([
        stewardEvent(triage, "one"), stewardEvent(other, "x"), stewardEvent(triage, "two"),
    ])
    return (store, signer)
}

@Test func anAuditExportHoldsTheStewardsLinesAndVerifies() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let (_, signer) = try auditedHome(home)
    let out = home.url.appendingPathComponent("export")
    let manifest = try AuditExport.write(
        home: home.url, steward: triage, to: out, signer: signer)
    #expect(manifest.count == 2)
    #expect(manifest.first == 2)
    #expect(manifest.last == 4)
    #expect(manifest.head == 4)
    #expect(manifest.payloads == nil)
    let lines = try String(contentsOf: out.appendingPathComponent("events.jsonl"), encoding: .utf8)
        .split(separator: "\n")
    #expect(lines.count == 2)
    #expect(try home.lines(1).contains(String(lines[0])))
    let check = AuditExport.verify(out)
    #expect(check.ok, "\(check.issues)")
    #expect(throws: AuditExportError.exists) {
        try AuditExport.write(home: home.url, steward: triage, to: out, signer: signer)
    }
}

@Test func tamperingWithAnyPartOfAnExportIsFound() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let (_, signer) = try auditedHome(home)
    let out = home.url.appendingPathComponent("export")
    try AuditExport.write(home: home.url, steward: triage, to: out, signer: signer)

    let events = out.appendingPathComponent("events.jsonl")
    let original = try Data(contentsOf: events)
    var text = String(decoding: original, as: UTF8.self)
    text = text.replacingOccurrences(of: "\"two\"", with: "\"too\"")
    try Data(text.utf8).write(to: events)
    #expect(
        AuditExport.verify(out).issues == [
            "events.jsonl does not match the manifest", "events.jsonl line 2 fails its hash",
        ])
    try original.write(to: events)

    let manifestURL = out.appendingPathComponent("manifest.json")
    var manifest = try JSONDecoder().decode(
        AuditManifest.self, from: try Data(contentsOf: manifestURL))
    manifest.count = 1
    try CanonicalJSON.encode(manifest).write(to: manifestURL)
    #expect(AuditExport.verify(out).issues.contains("the manifest signature does not verify"))

    try Data().write(to: out.appendingPathComponent("keys.jsonl"))
    #expect(
        AuditExport.verify(out).issues.contains(
            "the signing key \(signer.id) is not trusted by keys.jsonl"))
}

@Test func anEncryptedHomeExportsSealedLinesAndCanRevealThem() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let (store, signer) = try auditedHome(home)
    try HomeEncryption.enable(
        store: store, keys: MemoryHomeKeyStore(), key: try HomeKey(bytes: Array(0..<32)))
    try store.append(stewardEvent(triage, "secret"))
    let plain = home.url.appendingPathComponent("plain")
    let sealed = try AuditExport.write(home: home.url, steward: triage, to: plain, signer: signer)
    #expect(sealed.sealed == 1)
    #expect(sealed.payloads == nil)
    let opened = home.url.appendingPathComponent("opened")
    let revealed = try AuditExport.write(
        home: home.url, steward: triage, to: opened, signer: signer, reveal: true)
    #expect(revealed.payloads != nil)
    let payloads = try String(
        contentsOf: opened.appendingPathComponent("payloads.jsonl"), encoding: .utf8)
    #expect(payloads.contains("secret"))
    #expect(AuditExport.verify(plain).ok)
    #expect(AuditExport.verify(opened).ok)
}
