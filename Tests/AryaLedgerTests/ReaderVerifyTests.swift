import AryaCore
import Foundation
import Testing

@testable import AryaLedger

/// A ledger of `count` notes spread over several small segments.
private func multiSegment(_ home: TempHome, count: Int = 12) throws -> [Event] {
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 700)
    return try (0..<count).map { try store.append(note("event \($0)")) }
}

@Test func readerIteratesInOrderAndFromSeq() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let written = try multiSegment(home)
    let reader = LedgerReader(home: home.url)
    #expect(try LedgerStore(home: home.url, ambient: .fixed()).segments().count > 2)
    #expect(try reader.events() == written)
    #expect(try reader.events(from: 7) == Array(written[6...]))
    #expect(try reader.events(from: 13).isEmpty)
    #expect(try LedgerReader(home: home.url.appendingPathComponent("none")).events().isEmpty)
}

@Test func readerSkipsAnIncompleteFinalLine() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let first = try store.append(note("a"))
    let handle = try FileHandle(forWritingTo: home.segment(1))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"partial"#.utf8))
    try handle.close()
    #expect(try LedgerReader(home: home.url).events() == [first])
}

@Test func followSeesNewAppends() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    try store.append(note("before"))
    let stream = LedgerReader(home: home.url).follow(after: 1, interval: .milliseconds(10))
    let writer = Task {
        try await Task.sleep(for: .milliseconds(30))
        try store.append([note("x"), note("y")])
    }
    var seen: [Int64] = []
    for try await event in stream {
        seen.append(event.seq)
        if seen.count == 2 { break }
    }
    try await writer.value
    #expect(seen == [2, 3])
}

@Test func verifyPassesAGoodLedger() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let written = try multiSegment(home)
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.ok)
    #expect(verdict.events == 12)
    #expect(verdict.head == written.last?.hash)
    #expect(try LedgerVerifier(home: home.url.appendingPathComponent("none")).verify().ok)
}

@Test func verifyFindsOneTamperedByteInAMiddleSegment() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    _ = try multiSegment(home)
    let segments = try LedgerStore(home: home.url, ambient: .fixed()).segments()
    let middle = segments[segments.count / 2]
    var bytes = [UInt8](try Data(contentsOf: middle.url))
    let lines = try home.lines(middle.number)
    let secondLineStart = lines[0].utf8.count + 1
    let target = secondLineStart + Array(lines[1].utf8).firstIndex(of: UInt8(ascii: "v"))!
    bytes[target] = UInt8(ascii: "w")
    try Data(bytes).write(to: middle.url)

    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(!verdict.ok)
    #expect(verdict.failure?.location.segment == middle.name)
    #expect(verdict.failure?.location.line == 2)
    #expect(verdict.failure?.location.offset == Int64(secondLineStart))
    #expect(verdict.failure?.issue == .line(.hashMismatch))
    #expect(verdict.events == Int64(try LedgerLine.open(Array(lines[0].utf8)).seq))
}

@Test func verifyFindsGapsAndBrokenLinks() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    try LedgerStore(home: home.url, ambient: .fixed()).append([note("a"), note("b"), note("c")])
    var lines = try home.lines(1)
    lines.remove(at: 1)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: home.segment(1))
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.failure?.issue == .seqGap(expected: 2, found: 3))
    #expect(verdict.failure?.location.line == 2)
}

@Test func verifyFindsAForgedPrev() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let first = try LedgerStore(home: home.url, ambient: .fixed()).append(note("a"))
    // A correctly hashed line whose prev points nowhere.
    let (_, line) = try LedgerLine.seal(
        note("forged"), seq: 2, prev: String(repeating: "1", count: 64),
        id: EventID(rawValue: "ev_x")!, at: Timestamp(millis: 0))
    let handle = try FileHandle(forWritingTo: home.segment(1))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line + [0x0A]))
    try handle.close()
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.failure?.issue == .prevMismatch(seq: 2))
    #expect(verdict.head == first.hash)
}

@Test func verifyReportsATornTail() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    try LedgerStore(home: home.url, ambient: .fixed()).append(note("a"))
    let handle = try FileHandle(forWritingTo: home.segment(1))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"x".utf8))
    try handle.close()
    let verdict = try LedgerVerifier(home: home.url).verify()
    #expect(verdict.failure?.issue == .torn(repairable: true))
    #expect(verdict.failure?.location.line == 2)
    _ = try LedgerStore(home: home.url, ambient: .fixed())
    #expect(try LedgerVerifier(home: home.url).verify().ok)
}
