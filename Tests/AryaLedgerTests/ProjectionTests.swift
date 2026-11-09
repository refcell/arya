import AryaCore
import Foundation
import Testing

@testable import AryaLedger

private let steward2 = StewardID(rawValue: "st_inbox")!

/// Writes a deterministic mix of steward and run events.
private func populate(_ store: LedgerStore, from start: Int, count: Int) throws {
    let ambient = Ambient.fixed(seed: UInt64(start))
    for index in start..<(start + count) {
        let steward = index % 3 == 0 ? steward2 : triage
        let run: RunID? =
            index % 4 == 0 ? nil : RunID(body: "r\(index % 5)")
        try store.append(
            EventDraft(
                type: index % 2 == 0 ? .runDecision : .runToolCall, actor: .steward(steward),
                steward: steward, run: run,
                payload: ["n": .int(Int64(index)), "r": .int(Int64(ambient.random(in: 0..<9)))]))
    }
}

@Test func rebuildAndIncrementalAgree() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 2048)
    let reader = LedgerReader(home: home.url)
    var incremental = Projected<LedgerIndex>()
    for batch in 0..<5 {
        try populate(store, from: batch * 7, count: 7)
        #expect(try reader.catchUp(&incremental) == false)
    }
    let rebuilt = try reader.rebuild(LedgerIndex.self)
    #expect(incremental.value == rebuilt.value)
    #expect(incremental.seq == 35)
    #expect(incremental.hash == rebuilt.hash)
    #expect(rebuilt.value.events == 35)
    #expect(rebuilt.value.countsByType[.runDecision] == 18)
    #expect(rebuilt.value.eventsBySteward[steward2] == 12)
    #expect(try store.segments().count > 1)
}

@Test func catchUpIsANoOpWhenCurrent() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    try populate(store, from: 0, count: 3)
    let reader = LedgerReader(home: home.url)
    var projected = try reader.rebuild(LedgerIndex.self)
    let before = projected.value
    #expect(try reader.catchUp(&projected) == false)
    #expect(projected.value == before)
}

@Test func catchUpRebuildsWhenTheLedgerChangedUnderneath() throws {
    let a = try TempHome()
    defer { a.cleanup() }
    try populate(try LedgerStore(home: a.url, ambient: .fixed()), from: 0, count: 6)
    var projected = try LedgerReader(home: a.url).rebuild(LedgerIndex.self)
    // Replace the ledger with a different history of the same length.
    try FileManager.default.removeItem(at: a.url.appendingPathComponent("ledger"))
    try populate(try LedgerStore(home: a.url, ambient: .fixed(seed: 5)), from: 100, count: 6)
    #expect(try LedgerReader(home: a.url).catchUp(&projected) == true)
    #expect(projected.value == (try LedgerReader(home: a.url).rebuild(LedgerIndex.self)).value)
}

@Test func projectedRejectsGapsAndForks() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    try populate(store, from: 0, count: 3)
    let events = try LedgerReader(home: home.url).events()
    var projected = Projected<LedgerIndex>()
    #expect(throws: ProjectionError.discontinuity(expectedSeq: 1, found: 2)) {
        try projected.apply(events[1])
    }
    try projected.apply(events[0])
    var forked = events[1]
    forked.prev = String(repeating: "1", count: 64)
    #expect(throws: ProjectionError.self) { try projected.apply(forked) }
}

@Test func indexTracksRunSpans() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed(stepMillis: 1000))
    let run = RunID(body: "a")!
    try store.append(EventDraft(type: .runStarted, actor: .local, steward: triage, run: run))
    try store.append(EventDraft(type: .systemStarted, actor: .system))
    try store.append(EventDraft(type: .runFinished, actor: .system, steward: triage, run: run))
    let index = try LedgerReader(home: home.url).rebuild(LedgerIndex.self).value
    let span = try #require(index.runs[run])
    #expect(span.firstSeq == 1)
    #expect(span.lastSeq == 3)
    #expect(span.events == 2)
    #expect(span.lastAt.millis - span.startedAt.millis == 2000)
    #expect(index.runs(of: triage).map(\.0) == [run])
}

@Test func indexKeepsPerStewardCountersForStatusWidgets() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let types: [EventType] = [
        .runStarted, .runFinished, .runStarted, .runFailed, .approvalRequested,
        .approvalRequested, .approvalGranted, .metricRecorded, .approvalRequested,
        .approvalExpired, .metricRecorded,
    ]
    for type in types {
        try store.append(EventDraft(type: type, actor: .system, steward: triage))
    }
    try store.append(EventDraft(type: .runFailed, actor: .system, steward: steward2))
    let index = try LedgerReader(home: home.url).rebuild(LedgerIndex.self).value
    let span = try #require(index.stewards[triage])
    #expect(span.counts[.runStarted] == 2)
    #expect(span.counts[.runFinished] == 1 && span.counts[.runFailed] == 1)
    #expect(span.openApprovals == 1)
    #expect(span.lastSeqByType[.metricRecorded] == 11)
    #expect(span.firstSeq == 1 && span.lastSeq == 11)
    #expect(index.stewards[steward2]?.counts == [.runFailed: 1])
    // The counters survive the projection cache round trip.
    let cached = try ProjectionCache(home: home.url).current(LedgerIndex.self, name: "index")
    #expect(
        ProjectionCache(home: home.url).load(LedgerIndex.self, name: "index")?.value
            == cached.value)
}
