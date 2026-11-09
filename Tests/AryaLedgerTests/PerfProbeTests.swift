import AryaCore
import Foundation
import Testing

@testable import AryaLedger

// Perf probes run only with `ARYA_PERF=1 just test perf`, never in CI. They measure this
// thread's CPU time, not wall time, so a busy machine slows them less than it would a stopwatch.

private let perfEnabled = ProcessInfo.processInfo.environment["ARYA_PERF"] == "1"

/// CPU seconds this thread spends in `body`.
private func cpuSeconds(_ body: () throws -> Void) rethrows -> Double {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    try body()
    return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
}

private func format(_ seconds: Double) -> String {
    String(format: "%.3f s", seconds)
}

/// A store holding 5,000 events with a 400-byte text payload each.
private func filledHome() throws -> TempHome {
    let home = try TempHome()
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let payload: JSONValue = ["text": .string(String(repeating: "x", count: 400)), "n": 1]
    try store.append(
        (0..<5000).map { _ in EventDraft(type: .runDecision, actor: .local, payload: payload) })
    return home
}

/// Target from the ledger lane: a full read of 5,000 events under 0.3 s (debug build).
@Test(.enabled(if: perfEnabled)) func perfFullReadOf5000EventsIsUnderTarget() throws {
    let home = try filledHome()
    defer { home.cleanup() }
    let reader = LedgerReader(home: home.url)
    var count = 0
    let read = try cpuSeconds { count = try reader.events().count }
    let tail = try cpuSeconds { _ = try reader.events(from: 4990) }
    let verify = try cpuSeconds { _ = try LedgerVerifier(home: home.url).verify() }
    print("PERF read all: \(format(read)); read tail: \(format(tail)); verify: \(format(verify))")
    #expect(count == 5000)
    #expect(read < 0.3)
}

@Test(.enabled(if: perfEnabled)) func perfBreakdown() throws {
    let home = try filledHome()
    defer { home.cleanup() }
    let lines = try home.lines(1).map { Array($0.utf8) }
    let hash = cpuSeconds { for line in lines { _ = LedgerLine.hexSHA256(line) } }
    let parse = try cpuSeconds { for line in lines { _ = try JSONParser.parse(line) } }
    let open = try cpuSeconds { for line in lines { _ = try LedgerLine.open(line) } }
    let decoder = try cpuSeconds {
        for line in lines { _ = try JSONDecoder().decode(Event.self, from: Data(line)) }
    }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let append = try cpuSeconds {
        for _ in 0..<50 { try store.append(EventDraft(type: .runDecision, actor: .local)) }
    }
    print(
        "PERF hash: \(format(hash)); parse: \(format(parse)); open: \(format(open)); "
            + "JSONDecoder: \(format(decoder)); 50 single appends: \(format(append))")
}

/// 50,000 events (weeks of history) over 8 stewards and 5 types, one minute apart, with a
/// 300-byte payload each, in 4 MiB segments.
private func weeksHome() throws -> (TempHome, Timestamp) {
    let home = try TempHome()
    let start = Timestamp(millis: 1_767_225_600_000)
    let store = try LedgerStore(
        home: home.url, ambient: .fixed(start: start, stepMillis: 60_000),
        segmentLimitBytes: 4 << 20)
    let stewards = (0..<8).map { StewardID(rawValue: "st_s\($0)")! }
    let types: [EventType] = [
        .runDecision, .runStarted, .approvalGranted, .systemStarted, "metric.recorded",
    ]
    let payload: JSONValue = ["text": .string(String(repeating: "x", count: 300))]
    for batch in 0..<50 {
        try store.append(
            (0..<1000).map { index in
                let n = batch * 1000 + index
                return EventDraft(
                    type: types[n % 5], actor: .system, steward: stewards[n % 8], payload: payload)
            })
    }
    return (home, start)
}

/// Target from the ledger lane (5a): a filtered scan of 50,000 events under 0.5 s (debug).
@Test(.enabled(if: perfEnabled)) func perfFilteredScanOf50000EventsIsUnderTarget() throws {
    let (home, start) = try weeksHome()
    defer { home.cleanup() }
    let reader = LedgerReader(home: home.url)
    let steward = StewardID(rawValue: "st_s3")!
    var counts: [Int] = []
    let filtered = try cpuSeconds {
        counts.append(
            try reader.events(LedgerFilter(steward: steward, types: [.runDecision])).count)
    }
    let typed = try cpuSeconds {
        counts.append(try reader.events(LedgerFilter(namespaces: ["approval"])).count)
    }
    let lastWeek = start.adding(milliseconds: (50_000 - 10_080) * 60_000)
    let since = try cpuSeconds { counts.append(try reader.events(since: lastWeek).count) }
    let full = try cpuSeconds { counts.append(try reader.events().count) }
    let index = try reader.rebuild(LedgerIndex.self)
    let lateSteward = try cpuSeconds {
        _ = try reader.pageBackward(LedgerFilter(steward: steward), limit: 50, index: index)
    }
    print("PERF 50k: newest 50 of one steward, indexed \(format(lateSteward))")
    print(
        "PERF 50k: filtered \(format(filtered)); namespace \(format(typed)); "
            + "last week \(format(since)); full \(format(full)); counts \(counts)")
    #expect(counts == [1250, 10_000, 10_080, 50_000])
    #expect(filtered < 0.5)
}
