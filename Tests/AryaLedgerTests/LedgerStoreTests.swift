import AryaCore
import Foundation
import Testing

@testable import AryaLedger

@Test func appendsChainAndPersist() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let first = try store.append(note("one"))
    let rest = try store.append([note("two"), note("three")])
    #expect(first.seq == 1)
    #expect(first.prev == Event.genesisHash)
    #expect(rest.map(\.seq) == [2, 3])
    #expect(rest[0].prev == first.hash)
    #expect(rest[1].prev == rest[0].hash)
    let lines = try home.lines(1)
    #expect(lines.count == 3)
    #expect(try lines.map { try LedgerLine.open(Array($0.utf8)) } == [first] + rest)
    // A second store (another process) continues the chain from the tail.
    let other = try LedgerStore(home: home.url, ambient: .fixed(seed: 9))
    #expect(try other.head().seq == 3)
    let fourth = try other.append(note("four"))
    #expect(fourth.seq == 4)
    #expect(fourth.prev == rest[1].hash)
}

@Test func storesAreDeterministicUnderFixedAmbient() throws {
    let a = try TempHome()
    let b = try TempHome()
    defer {
        a.cleanup()
        b.cleanup()
    }
    for home in [a, b] {
        let store = try LedgerStore(home: home.url, ambient: .fixed(seed: 4))
        try store.append([note("x"), note("y")])
    }
    #expect(try Data(contentsOf: a.segment(1)) == Data(contentsOf: b.segment(1)))
}

@Test func rollsOverSegments() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 700)
    var events: [Event] = []
    for index in 0..<6 { events.append(try store.append(note("event \(index)"))) }
    events += try store.append((6..<10).map { note("event \($0)") })
    let segments = try store.segments()
    #expect(segments.count > 2)
    var all: [Event] = []
    for segment in segments {
        let size = try FileManager.default.attributesOfItem(atPath: segment.url.path)[.size] as! Int
        #expect(size <= 700)
        all += try home.lines(segment.number).map { try LedgerLine.open(Array($0.utf8)) }
    }
    #expect(all == events)
    #expect(all.map(\.seq) == Array(1...10))
    #expect(try store.head().seq == 10)
}

@Test func oversizedLineStillGetsWritten() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 10)
    try store.append([note("a"), note("b")])
    #expect(try store.segments().map(\.number) == [1, 2])
}

@Test func repairsTornLineWithoutNewline() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let first = try LedgerStore(home: home.url, ambient: .fixed()).append(note("kept"))
    let handle = try FileHandle(forWritingTo: home.segment(1))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"actor":{"id":"loc"#.utf8))
    try handle.close()

    let store = try LedgerStore(home: home.url, ambient: .fixed(seed: 2))
    let lines = try home.lines(1).map { try LedgerLine.open(Array($0.utf8)) }
    #expect(lines.count == 2)
    #expect(lines[0] == first)
    let repair = try lines[1].payload(as: SystemRepair.self)
    #expect(lines[1].prev == first.hash)
    #expect(lines[1].actor == .system)
    #expect(repair.reason == "no trailing newline")
    #expect(repair.segment == "000001.jsonl")
    #expect(try store.blobs.get(repair.blob) == Data(#"{"actor":{"id":"loc"#.utf8))
    #expect(try store.append(note("after")).seq == 3)
}

@Test func repairsTornLineThatIsNotJSON() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    try LedgerStore(home: home.url, ambient: .fixed()).append(note("kept"))
    let handle = try FileHandle(forWritingTo: home.segment(1))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"half\n".utf8))
    try handle.close()
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let last = try LedgerLine.open(Array(try home.lines(1).last!.utf8))
    #expect(try last.payload(as: SystemRepair.self).reason == "not JSON")
    #expect(try store.head().seq == 2)
}

@Test func refusesToAppendAfterAChainBreak() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    try LedgerStore(home: home.url, ambient: .fixed()).append([note("a"), note("b")])
    var text = String(decoding: try Data(contentsOf: home.segment(1)), as: UTF8.self)
    text = text.replacingOccurrences(of: #""text":"b""#, with: #""text":"c""#)
    try Data(text.utf8).write(to: home.segment(1))
    #expect {
        try LedgerStore(home: home.url, ambient: .fixed())
    } throws: { error in
        guard case LedgerStoreError.chainBroken(let segment, _, .hashMismatch) = error else {
            return false
        }
        return segment == "000001.jsonl"
    }
}
