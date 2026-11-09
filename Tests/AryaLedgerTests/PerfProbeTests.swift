import AryaCore
import Foundation
import Testing

@testable import AryaLedger

@Test(.enabled(if: ProcessInfo.processInfo.environment["ARYA_PERF"] == "1"))
func perfProbe() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let clock = ContinuousClock()
    let payload: JSONValue = ["text": .string(String(repeating: "x", count: 400)), "n": 1]
    let appendTime = try clock.measure {
        for _ in 0..<20 {
            try store.append(
                (0..<250).map { _ in EventDraft(type: .runDecision, actor: .local, payload: payload)
                })
        }
    }
    let single = try clock.measure {
        for _ in 0..<50 {
            try store.append(EventDraft(type: .runDecision, actor: .local, payload: payload))
        }
    }
    let readTime = try clock.measure { _ = try LedgerReader(home: home.url).events() }
    let tailTime = try clock.measure { _ = try LedgerReader(home: home.url).events(from: 5040) }
    print(
        "PERF batch-append 5000: \(appendTime); 50 single appends: \(single); "
            + "read all: \(readTime); read tail: \(tailTime)"
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ARYA_PERF"] == "1"))
func perfBreakdown() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let payload: JSONValue = ["text": .string(String(repeating: "x", count: 400)), "n": 1]
    try store.append(
        (0..<5000).map { _ in EventDraft(type: .runDecision, actor: .local, payload: payload) })
    let lines = try home.lines(1).map { Data($0.utf8) }
    let clock = ContinuousClock()
    let hash = clock.measure { for l in lines { _ = LedgerLine.hexSHA256(l) } }
    let decoder = try clock.measure {
        for l in lines { _ = try JSONDecoder().decode(Event.self, from: l) }
    }
    let reader = LedgerReader(home: home.url)
    let segment = try reader.existingSegments()[0]
    var count = 0
    let scan = try clock.measure { try reader.scanLines(segment) { _, _, _ in count += 1 } }
    let open = try clock.measure { for l in lines { _ = try LedgerLine.open(l) } }
    print("PERF hash: \(hash); decode: \(decoder); scan: \(scan) (\(count)); open: \(open)")
}
