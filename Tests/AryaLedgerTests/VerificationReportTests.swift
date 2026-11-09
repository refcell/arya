import AryaCore
import Foundation
import Testing

@testable import AryaLedger

@Test func reportForAGoodLedger() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    #expect(
        try LedgerVerifier(home: home.url).verify().report.text
            == "ledger ok: 0 events in 0 segments\nhead: \(Event.genesisHash)")
    let event = try LedgerStore(home: home.url, ambient: .fixed()).append(note("a"))
    let report = try LedgerVerifier(home: home.url).verify().report
    #expect(report.ok)
    #expect(report.lines == ["ledger ok: 1 event in 1 segment", "head: \(event.hash)"])
}

@Test func reportForATamperedLine() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let events = try LedgerStore(home: home.url, ambient: .fixed())
        .append([note("a"), note("b"), note("c")])
    let lines = try home.lines(1)
    let tampered = lines[1].replacingOccurrences(of: "\"b\"", with: "\"B\"")
    let text = [lines[0], tampered, lines[2]].joined(separator: "\n") + "\n"
    try Data(text.utf8).write(to: home.segment(1))
    let report = try LedgerVerifier(home: home.url).verify().report
    #expect(!report.ok)
    #expect(
        report.text == """
            ledger broken at seq 2: hash mismatch
            where: 000001.jsonl line 2, byte \(lines[0].utf8.count + 1)
            verified: 1 event before it, in 1 segment; last good head \(events[0].hash)
            meaning: the line's bytes changed after it was written.
            next: stop writing to this home and restore the named segment from a backup; \
            events after the break cannot be trusted.
            """)
}

@Test func reportForATornTailSaysItRepairsItself() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    try LedgerStore(home: home.url, ambient: .fixed()).append(note("a"))
    let handle = try FileHandle(forWritingTo: home.segment(1))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"x".utf8))
    try handle.close()
    let report = try LedgerVerifier(home: home.url).verify().report
    #expect(report.headline == "ledger broken at seq 2: torn final line (repaired on next open)")
    #expect(report.details.last?.hasPrefix("next: nothing;") == true)
}

@Test func reportsAreStableForEveryIssue() {
    let issues: [LedgerVerification.Issue] = [
        .line(.hashMismatch), .line(.tooShort), .line(.missingHashSuffix),
        .line(.badEnvelope("seq")), .seqGap(expected: 4, found: 6), .prevMismatch(seq: 4),
        .torn(repairable: true), .torn(repairable: false),
    ]
    for issue in issues {
        let verdict = LedgerVerification(
            events: 3, head: Event.genesisHash, segments: 2,
            failure: .init(
                location: .init(segment: "000002.jsonl", line: 1, offset: 0),
                issue: issue))
        let report = verdict.report
        #expect(report == verdict.report)
        #expect(report.headline == "ledger broken at seq 4: \(issue)")
        #expect(
            report.details.map { $0.prefix { $0 != ":" } } == [
                "where", "verified", "meaning", "next",
            ])
        #expect(report.details.suffix(2).allSatisfy { $0.hasSuffix(".") })
    }
}
