import AryaCore
import Foundation
import Testing

@testable import AryaLedger

private let fixedKey = try! HomeKey(bytes: Array(0..<32))

/// A store over a fresh home with encryption enabled under `fixedKey`.
private func encrypted(_ home: TempHome, keys: MemoryHomeKeyStore = MemoryHomeKeyStore())
    throws -> LedgerStore
{
    let store = try LedgerStore(home: home.url, ambient: .fixed(seed: 7))
    try HomeEncryption.enable(store: store, keys: keys, key: fixedKey)
    return store
}

private func stewardNote(_ text: String) -> EventDraft {
    EventDraft(
        type: "test.note", actor: .local, steward: triage, payload: ["text": .string(text)])
}

@Test func sealedPayloadsReadBackAndKeepTheEnvelopeClear() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try encrypted(home)
    let written = try store.append(stewardNote("refund the order"))
    #expect(written.payload == ["text": "refund the order"])

    let raw = try home.lines(1)
    #expect(raw.count == 2)
    #expect(raw[0].contains(#""type":"system.encryption.enabled""#))
    #expect(raw[0].contains(fixedKey.id))
    #expect(!raw[1].contains("refund"))
    #expect(raw[1].contains(#""sealed":{"box":""#))
    #expect(raw[1].contains(#""steward":"st_triage""#))

    let reader = LedgerReader(home: home.url)
    #expect(try reader.events().map(\.payload).last == ["text": "refund the order"])
    #expect(try reader.events().last == written)
    // The sieve still narrows by envelope fields.
    #expect(try reader.events(LedgerFilter(steward: triage)).map(\.seq) == [2])
    #expect(try reader.newest(LedgerFilter(steward: triage), limit: 5).map(\.seq) == [2])
    #expect(try LedgerVerifier(home: home.url).verify().ok)
}

@Test func aLockedHomeVerifiesButRefusesToReadOrWrite() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try encrypted(home)
    try store.append(stewardNote("secret"))

    HomeEncryption.register(home: home.url, keys: MemoryHomeKeyStore())
    #expect(try LedgerVerifier(home: home.url).verify().ok)
    #expect(throws: HomeEncryptionError.locked(key: fixedKey.id)) {
        _ = try LedgerReader(home: home.url).events()
    }
    #expect(throws: HomeEncryptionError.locked(key: fixedKey.id)) {
        try store.append(stewardNote("more"))
    }
    var types: [EventType] = []
    try LedgerReader(home: home.url).forEachEnvelope { types.append($0.type) }
    #expect(types == [.systemEncryptionEnabled, "test.note"])

    let keys = MemoryHomeKeyStore()
    try keys.save(fixedKey)
    HomeEncryption.register(home: home.url, keys: keys)
    #expect(try LedgerReader(home: home.url).events().count == 2)
}

@Test func sealingIsDeterministicAndBoundToItsEvent() throws {
    let first = try TempHome()
    let second = try TempHome()
    defer {
        first.cleanup()
        second.cleanup()
    }
    for home in [first, second] { try encrypted(home).append(stewardNote("same")) }
    #expect(try first.lines(1) == second.lines(1))

    let cipher = HomeCipher(key: fixedKey)
    let box = try cipher.seal(Array("x".utf8), context: "event|a")
    #expect(try cipher.open(box, context: "event|a") == Array("x".utf8))
    #expect(throws: HomeEncryptionError.badBox) { try cipher.open(box, context: "event|b") }
    let other = HomeCipher(key: try HomeKey(bytes: Array(repeating: 9, count: 32)))
    #expect(throws: HomeEncryptionError.badBox) { try other.open(box, context: "event|a") }
}

@Test func eventsWrittenBeforeEnablingStayInTheClear() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(seed: 7))
    try store.append(stewardNote("before"))
    try HomeEncryption.enable(store: store, keys: MemoryHomeKeyStore(), key: fixedKey)
    try store.append(stewardNote("after"))
    let raw = try home.lines(1)
    #expect(raw[0].contains("before"))
    #expect(!raw[2].contains("after"))
    let texts = try LedgerReader(home: home.url).events().compactMap { $0.payload["text"] }
    #expect(texts == ["before", "after"])
    #expect(try LedgerVerifier(home: home.url).verify().ok)
    // Enabling again keeps the first key.
    let again = try HomeEncryption.enable(store: store, keys: MemoryHomeKeyStore())
    #expect(again.key == fixedKey.id)
}

@Test func blobsAreSealedMigratedAndChecked() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let plain = BlobStore(home: home.url)
    let old = try plain.put(Data("old blob".utf8))
    let store = try encrypted(home)
    let blobs = store.blobs
    let new = try blobs.put(Data("new blob".utf8))
    for hex in [old, new] {
        let bytes = try #require(FileManager.default.contents(atPath: blobs.path(hex).path))
        #expect(HomeEncryption.isSealedFile(bytes))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("blob"))
    }
    #expect(try blobs.get(old) == Data("old blob".utf8))
    #expect(try blobs.get(new) == Data("new blob".utf8))
    #expect(try blobs.keys() == [old, new].sorted())
    #expect(try HomeEncryption.migrate(home.url) == 0)

    var bytes = try #require(FileManager.default.contents(atPath: blobs.path(new).path))
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: blobs.path(new))
    #expect(throws: BlobError.corrupt(new)) { try blobs.get(new) }
}

@Test func projectionCachesAreSealedAndReload() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(seed: 7))
    try store.append(stewardNote("one"))
    let cache = ProjectionCache(home: home.url)
    _ = try cache.index()
    try HomeEncryption.enable(store: store, keys: MemoryHomeKeyStore(), key: fixedKey)
    #expect(!FileManager.default.fileExists(atPath: cache.url(ProjectionCache.indexName).path))

    try store.append(stewardNote("two"))
    let built = try cache.index()
    let bytes = try #require(
        FileManager.default.contents(atPath: cache.url(ProjectionCache.indexName).path))
    #expect(HomeEncryption.isSealedFile(bytes))
    let loaded = try #require(cache.load(LedgerIndex.self, name: ProjectionCache.indexName))
    #expect(loaded.seq == built.seq)
    #expect(loaded.value == built.value)
}

@Test func anUnreadableSettingIsAnError() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let url = HomeEncryption.configURL(home.url)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"v":2}"#.utf8).write(to: url)
    #expect(throws: HomeEncryptionError.badConfig) { try HomeEncryption.config(home.url) }
    #expect(throws: HomeEncryptionError.badKey) { try HomeKey(bytes: [1, 2, 3]) }
    #expect(HomeKey.generate().id.hasPrefix("hk_"))
}
