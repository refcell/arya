import AryaCore
import CryptoKit
import Foundation
import Testing

@testable import AryaLedger

private func fixedKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
    // A 32-byte seed always makes a valid Ed25519 key.
    try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
}

private func keyEvents(_ home: TempHome) throws -> [SystemKeyAdded] {
    try LedgerReader(home: home.url).events(SystemKeyAdded.self).map(\.payload)
}

@Test func ensureCreatesAPrivateKeyFileAndRecordsItOnce() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let keys = CheckpointKeys(home: home.url)
    #expect(try keys.load() == nil)
    let signer = try keys.ensure(store: store) { fixedKey(1) }
    #expect(signer.id.hasPrefix("key_") && signer.id.count == 20)
    #expect(try keys.load()?.id == signer.id)
    let mode = try FileManager.default.attributesOfItem(atPath: keys.url.path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o600)
    #expect(try keys.ensure(store: store) { fixedKey(2) }.id == signer.id)
    let recorded = try keyEvents(home)
    #expect(recorded.map(\.key) == [signer.id])
    #expect(recorded[0].replaces == nil && recorded[0].signature == nil)
    let ring = try KeyRing.read(LedgerReader(home: home.url))
    #expect(ring.current == signer.id && ring.rejected.isEmpty)
    // The ledger never holds the private key.
    let text = try home.lines(1).joined()
    #expect(!text.contains(signer.privateKey.rawRepresentation.base64EncodedString()))
}

@Test func rotationIsSignedByTheOldKeyAndRetiresItsFile() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let keys = CheckpointKeys(home: home.url)
    let first = try keys.ensure(store: store) { fixedKey(1) }
    let second = try keys.rotate(store: store) { fixedKey(2) }
    #expect(try keys.load()?.id == second.id)
    let retired = keys.directory.appendingPathComponent("retired/\(first.id).key")
    #expect(FileManager.default.fileExists(atPath: retired.path))
    let ring = try KeyRing.read(LedgerReader(home: home.url))
    #expect(Set(ring.keys.keys) == [first.id, second.id])
    #expect(ring.current == second.id && ring.rejected.isEmpty)
    #expect(try keyEvents(home).last?.replaces == first.id)
    // The rotated home still ensures without recording anything new.
    _ = try keys.ensure(store: store)
    #expect(try keyEvents(home).count == 2)
}

@Test func keyRingRejectsForgedAndUnsignedKeys() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let first = try CheckpointKeys(home: home.url).ensure(store: store) { fixedKey(1) }
    func added(_ key: Curve25519.Signing.PrivateKey, replaces: String?, signer: CheckpointSigner?)
        throws -> SystemKeyAdded
    {
        let new = CheckpointSigner(key)
        var payload = SystemKeyAdded(
            key: new.id, publicKey: new.publicKey.rawRepresentation.base64EncodedString(),
            replaces: replaces)
        if let signer { payload.signature = try signer.sign(CanonicalJSON.bytes(payload)) }
        return payload
    }
    var wrongID = try added(fixedKey(5), replaces: first.id, signer: first)
    wrongID.key = "key_0000000000000000"
    let forged = [
        try added(fixedKey(3), replaces: nil, signer: nil),
        try added(fixedKey(4), replaces: first.id, signer: CheckpointSigner(fixedKey(9))),
        try added(fixedKey(6), replaces: "key_ffffffffffffffff", signer: first),
        wrongID,
    ]
    for payload in forged { try store.append(EventDraft(payload, actor: .system)) }
    let ring = try KeyRing.read(LedgerReader(home: home.url))
    #expect(Array(ring.keys.keys) == [first.id])
    #expect(ring.rejected == [2, 3, 4, 5])
    // A stored key the ledger does not know cannot be recorded unsigned.
    let other = try TempHome()
    defer { other.cleanup() }
    _ = try CheckpointKeys(home: other.url).ensure(
        store: try LedgerStore(home: other.url, ambient: .fixed())
    ) { fixedKey(7) }
    try FileManager.default.removeItem(at: CheckpointKeys(home: home.url).url)
    try FileManager.default.copyItem(
        at: CheckpointKeys(home: other.url).url, to: CheckpointKeys(home: home.url).url)
    #expect(throws: CheckpointKeyError.notRecorded) {
        try CheckpointKeys(home: home.url).ensure(store: store)
    }
}

@Test func unreadableKeyFilesAndMissingKeysThrow() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let keys = CheckpointKeys(home: home.url)
    #expect(throws: CheckpointKeyError.noKey) { try keys.rotate(store: store) }
    try FileManager.default.createDirectory(at: keys.directory, withIntermediateDirectories: true)
    try Data("{\"v\":1}\n".utf8).write(to: keys.url)
    #expect(throws: CheckpointKeyError.unreadable) { try keys.load() }
}
