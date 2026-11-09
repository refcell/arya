import AryaCore
import Foundation
import Testing

@testable import AryaLedger

private let other = StewardID(rawValue: "st_inbox")!
private let runA = RunID(body: "a")!

/// 20 events: alternating stewards; every third in run a; types cycle run/approval/system.
private func seeded(_ home: TempHome) throws -> [Event] {
    let store = try LedgerStore(home: home.url, ambient: .fixed(), segmentLimitBytes: 1500)
    let types: [EventType] = [.runDecision, .approvalGranted, .systemStarted]
    return try (0..<20).map { index in
        try store.append(
            EventDraft(
                type: types[index % 3], actor: index % 4 == 0 ? .local : .system,
                steward: index % 2 == 0 ? triage : other, run: index % 3 == 0 ? runA : nil))
    }
}

@Test func filtersMatchEveryField() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let all = try seeded(home)
    let reader = LedgerReader(home: home.url)
    func seqs(_ filter: LedgerFilter) throws -> [Int64] {
        try reader.page(filter, limit: 100).events.map(\.seq)
    }
    #expect(try seqs(LedgerFilter()) == all.map(\.seq))
    #expect(
        try seqs(LedgerFilter(steward: triage)) == all.filter { $0.steward == triage }.map(\.seq))
    #expect(try seqs(LedgerFilter(run: runA)) == [1, 4, 7, 10, 13, 16, 19])
    #expect(try seqs(LedgerFilter(types: [.approvalGranted])).count == 7)
    #expect(try seqs(LedgerFilter(namespaces: ["system"])) == [3, 6, 9, 12, 15, 18])
    #expect(try seqs(LedgerFilter(actorKind: .human, actorID: "local")) == [1, 5, 9, 13, 17])
    #expect(try seqs(LedgerFilter(steward: triage, run: runA)) == [1, 7, 13, 19])
}

@Test func pagesForwardBySeq() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    _ = try seeded(home)
    let reader = LedgerReader(home: home.url)
    var cursor: Int64 = 0
    var seen: [Int64] = []
    var pages = 0
    while true {
        let page = try reader.page(LedgerFilter(steward: triage), after: cursor, limit: 3)
        seen += page.events.map(\.seq)
        pages += 1
        guard let next = page.next else { break }
        cursor = next
    }
    #expect(seen == Array(stride(from: 1, through: 19, by: 2)))
    #expect(pages == 4)
}

@Test func pagesBackwardFromNewest() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    _ = try seeded(home)
    let reader = LedgerReader(home: home.url)
    let newest = try reader.pageBackward(limit: 5)
    #expect(newest.events.map(\.seq) == [16, 17, 18, 19, 20])
    #expect(newest.next == 16)
    let older = try reader.pageBackward(before: newest.next, limit: 5)
    #expect(older.events.map(\.seq) == [11, 12, 13, 14, 15])
    let oldest = try reader.pageBackward(before: 3, limit: 5)
    #expect(oldest.events.map(\.seq) == [1, 2])
    #expect(oldest.next == nil)
}
