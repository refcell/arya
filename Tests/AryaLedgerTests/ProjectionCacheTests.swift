import AryaCore
import Foundation
import Testing

@testable import AryaLedger

private func appendNotes(_ store: LedgerStore, _ count: Int, run: String = "a") throws {
    try store.append(
        (0..<count).map { _ in
            EventDraft(type: .runDecision, actor: .local, steward: triage, run: RunID(body: run))
        })
}

@Test func cacheSavesLoadsAndCatchesUp() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let cache = ProjectionCache(home: home.url)
    try appendNotes(store, 4)
    let first = try cache.current(LedgerIndex.self, name: "ledger-index")
    #expect(first.seq == 4)
    let saved = try #require(cache.load(LedgerIndex.self, name: "ledger-index"))
    #expect(saved.seq == 4)
    #expect(saved.value == first.value)
    try appendNotes(store, 3, run: "b")
    let second = try cache.current(LedgerIndex.self, name: "ledger-index")
    #expect(second.seq == 7)
    #expect(second.value == (try LedgerReader(home: home.url).rebuild(LedgerIndex.self)).value)
    #expect(cache.load(LedgerIndex.self, name: "ledger-index")?.seq == 7)
}

@Test func cacheIsDeleteSafeAndIgnoresGarbage() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let cache = ProjectionCache(home: home.url)
    try appendNotes(store, 2)
    let expected = try cache.current(LedgerIndex.self, name: "idx").value
    try FileManager.default.removeItem(at: home.url.appendingPathComponent("cache"))
    #expect(try cache.current(LedgerIndex.self, name: "idx").value == expected)
    try Data("not json".utf8).write(to: cache.url("idx"))
    #expect(cache.load(LedgerIndex.self, name: "idx") == nil)
    #expect(try cache.current(LedgerIndex.self, name: "idx").value == expected)
}

@Test func staleCacheFromAnotherLedgerIsRebuilt() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let cache = ProjectionCache(home: home.url)
    try appendNotes(try LedgerStore(home: home.url, ambient: .fixed()), 5)
    _ = try cache.current(LedgerIndex.self, name: "idx")
    try FileManager.default.removeItem(at: home.url.appendingPathComponent("ledger"))
    try appendNotes(try LedgerStore(home: home.url, ambient: .fixed(seed: 3)), 2, run: "z")
    let fresh = try cache.current(LedgerIndex.self, name: "idx")
    #expect(fresh.seq == 2)
    #expect(fresh.value.runs.keys.map(\.rawValue) == ["run_z"])
}

@Test func cacheNamesAreSafe() {
    #expect(ProjectionCache.isValidName("stewards.v1"))
    #expect(!ProjectionCache.isValidName("../x"))
    #expect(!ProjectionCache.isValidName(".hidden"))
    #expect(!ProjectionCache.isValidName("A"))
}
