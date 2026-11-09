import AryaCore
import Foundation
import Testing

@testable import AryaLedger

private let inbox = StewardID(rawValue: "st_inbox")!
private let runA = RunID(body: "a")!
private let runB = RunID(body: "b")!
private let start = Timestamp(millis: 1_767_225_600_000)

/// Actors with ids the canonical writer must escape, so the sieve's needles are tested
/// against escaped bytes.
private let actors: [Actor] = [
    .local, .system, .steward(triage), .human(#"person:"quoted""#), .adapter("prof\\ile"),
    .human("person:zoë"), .human(#"x","kind":"system"}"#),
]

/// 120 events one second apart over 1,500-byte segments. Payloads carry decoy fragments
/// (`"steward":"st_triage"`, `"type":"approval.granted"`, `"at":"…"`) so the sieve sees
/// false positives it must leave to the full filter.
private func seeded(_ home: TempHome) throws -> [Event] {
    let store = try LedgerStore(
        home: home.url, ambient: .fixed(start: start, stepMillis: 1000),
        segmentLimitBytes: 1500)
    let types: [EventType] = [.runDecision, .approvalGranted, .systemStarted, "runner.odd"]
    let decoys: [JSONValue] = [
        ["steward": "st_triage", "run": .string(runA.rawValue)],
        ["type": "approval.granted", "kind": "system"],
        ["at": "2030-01-01T00:00:00.000Z", "id": "local"],
        [:],
    ]
    return try (0..<120).map { index in
        try store.append(
            EventDraft(
                type: types[index % 4], actor: actors[index % actors.count],
                steward: [triage, inbox, nil][index % 3],
                run: [runA, nil, runB, nil, nil][index % 5],
                payload: decoys[index % decoys.count]))
    }
}

private func filters() -> [LedgerFilter] {
    var out: [LedgerFilter] = [
        LedgerFilter(), LedgerFilter(steward: triage), LedgerFilter(steward: inbox, run: runB),
        LedgerFilter(run: runA), LedgerFilter(types: [.approvalGranted]),
        LedgerFilter(types: [.runDecision, .systemStarted]), LedgerFilter(namespaces: ["run"]),
        LedgerFilter(namespaces: ["runner", "system"]), LedgerFilter(actorKind: .system),
        LedgerFilter(actorKind: .human, actorID: "local"),
        LedgerFilter(since: start.adding(milliseconds: 40_000)),
        LedgerFilter(until: start.adding(milliseconds: 10_500)),
        LedgerFilter(
            steward: triage, types: [.approvalGranted], since: start.adding(milliseconds: 30_000),
            until: start.adding(milliseconds: 90_000)),
    ]
    out += actors.map { LedgerFilter(actorKind: $0.kind, actorID: $0.id) }
    out += actors.map { LedgerFilter(actorID: $0.id) }
    return out
}

@Test func sievedReadsEqualFullFilteredReads() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let all = try seeded(home)
    let reader = LedgerReader(home: home.url)
    #expect(try reader.events() == all)
    #expect(try home.lines(3).isEmpty == false)
    for filter in filters() {
        for from in [Int64(1), 2, 37, 119, 121] {
            let expected = all.filter { $0.seq >= from && filter.matches($0) }
            #expect(try reader.events(filter, from: from) == expected, "\(filter) from \(from)")
        }
    }
}

@Test func sinceReadSkipsEarlierSegmentsAndKeepsBoundaryEvents() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let all = try seeded(home)
    let reader = LedgerReader(home: home.url)
    for offset in [Int64(0), 999, 1000, 59_000, 119_000, 119_001, 500_000] {
        let since = start.adding(milliseconds: offset)
        #expect(try reader.events(since: since) == all.filter { $0.at >= since })
    }
    // Segments before the bound are read only for their first line: damage after it does
    // not fail the read.
    let first = home.segment(1)
    var bytes = try Data(contentsOf: first)
    bytes[bytes.count - 100] ^= 0x01
    try bytes.write(to: first)
    let late = start.adding(milliseconds: 100_000)
    #expect(try reader.events(since: late) == all.filter { $0.at >= late })
    #expect(throws: LedgerReadError.self) { try reader.events() }
}

@Test func typedReadDecodesOnlyItsType() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    let approvals = try (0..<5).map { ApprovalID(rawValue: "ap_\($0)")! }
    for (index, approval) in approvals.enumerated() {
        try store.append(note("before \(index)"))
        try store.append(
            EventDraft(
                ApprovalGranted(approval: approval), actor: .local,
                steward: index % 2 == 0 ? triage : inbox))
    }
    let reader = LedgerReader(home: home.url)
    let granted = try reader.events(ApprovalGranted.self)
    #expect(granted.map(\.payload.approval) == approvals)
    let triaged = try reader.events(ApprovalGranted.self, matching: LedgerFilter(steward: triage))
    #expect(triaged.map(\.payload.approval) == [approvals[0], approvals[2], approvals[4]])
    let none = try reader.events(
        ApprovalGranted.self, matching: LedgerFilter(types: [.approvalDenied]))
    #expect(none.isEmpty)
}

@Test func pageBackwardStopsAtItsCursor() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let all = try seeded(home)
    let reader = LedgerReader(home: home.url)
    let filter = LedgerFilter(steward: triage)
    let page = try reader.pageBackward(filter, before: 60, limit: 5)
    let expected = all.filter { $0.seq < 60 && filter.matches($0) }.suffix(5)
    #expect(page.events == Array(expected))
    #expect(page.next == expected.first?.seq)
}

@Test func indexNarrowedQueriesEqualPlainOnes() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let all = try seeded(home)
    let reader = LedgerReader(home: home.url)
    // Built over the first 60 events only: a stale index must still give the same answers.
    var stale = Projected<LedgerIndex>()
    for event in all.prefix(60) { try stale.apply(event) }
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 1500)
    let late = StewardID(rawValue: "st_late")!
    let lateRun = RunID(body: "late")!
    try store.append(EventDraft(type: .runDecision, actor: .system, steward: late, run: lateRun))
    let fresh = try reader.rebuild(LedgerIndex.self)
    #expect(fresh.value.stewards[late]?.firstSeq == 121)
    let queries =
        filters() + [
            LedgerFilter(steward: late), LedgerFilter(run: lateRun),
            LedgerFilter(steward: inbox, run: runB, types: [.systemStarted]),
        ]
    for index in [stale, fresh] {
        for filter in queries {
            #expect(try reader.events(filter, index: index) == reader.events(filter, from: 1))
            #expect(
                try reader.page(filter, after: 3, limit: 4, index: index)
                    == reader.page(filter, after: 3, limit: 4))
            #expect(
                try reader.pageBackward(filter, before: 100, limit: 4, index: index)
                    == reader.pageBackward(filter, before: 100, limit: 4))
        }
    }
}
