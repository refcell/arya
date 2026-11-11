import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private func filler(_ count: Int) -> [EventDraft] {
    (0..<count).map { index in
        EventDraft(
            type: EventType("test.filler"), actor: Actor(kind: .system, id: "test"),
            steward: nil, run: nil, payload: ["n": .string(String(index))])
    }
}

private func store(_ opened: Opened) throws -> LedgerStore {
    try LedgerStore(home: opened.home.url, ambient: Ambient.fixed(stepMillis: 1))
}

@Test func readsFoldOnlyTheEventsAppendedSinceTheLastRead() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "Sort MSG-9")
    let first = try workspace.facadeState()
    #expect(first.seq == Int64(try await workspace.lastSeq()))
    #expect(try await workspace.approvals().count == 1)

    let before = try await workspace.lastSeq()
    _ = try await workspace.remember("Card updates are billing.", steward: "st_inbox")
    try store(opened).append(filler(5))
    let added = try await workspace.lastSeq() - before

    let second = try workspace.facadeState()
    #expect(second.applied - first.applied == added)
    #expect(second.rebuilds == first.rebuilds)
    // Nothing new: the read folds nothing.
    #expect(try workspace.facadeState().applied == second.applied)
    #expect(try await workspace.runs().count == 1)
}

@Test func aFreshWorkspaceStartsFromTheDiskCacheAndRebuildsAfterARestore() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "Sort MSG-9")
    _ = try workspace.facadeState()
    let ledger = opened.home.url.appendingPathComponent("ledger")
    let saved = opened.home.url.appendingPathComponent("saved-ledger")
    try FileManager.default.copyItem(at: ledger, to: saved)
    try store(opened).append(filler(3))
    let grown = try workspace.facadeState()

    // Put the shorter ledger back: the cached state is ahead of it and must be rebuilt.
    try FileManager.default.removeItem(at: ledger)
    try FileManager.default.moveItem(at: saved, to: ledger)
    try? FileManager.default.removeItem(at: opened.home.url.appendingPathComponent("cache"))
    let restored = try workspace.facadeState()
    #expect(restored.seq == grown.seq - 3)
    #expect(restored.rebuilds == grown.rebuilds + 1)
    #expect(try await workspace.approvals().count == 1)
}

@Test func warmApprovalsOnALargeHomeAreFast() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "Sort MSG-9")
    for _ in 0..<10 { try store(opened).append(filler(5_000)) }
    #expect(try await workspace.lastSeq() > 50_000)

    #expect(try await workspace.approvals().count == 1)  // cold: builds the cache
    let run = try #require(try await workspace.runs().first).id
    let reads: [(String, () async throws -> Void)] = [
        ("approvals", { _ = try await workspace.approvals() }),
        ("fleet", { _ = try await workspace.fleet() }),
        ("needsYou", { _ = try await workspace.needsYou() }),
        ("liveRuns", { _ = try await workspace.liveRuns() }),
        ("activity", { _ = try await workspace.activity(steward: "st_inbox") }),
        ("recap", { _ = try await workspace.recap(steward: "st_inbox") }),
        ("plan", { _ = try await workspace.plan(steward: "st_inbox") }),
        ("event", { _ = try await workspace.event(seq: 3) }),
        ("conversation", { _ = try await workspace.conversation(steward: "st_inbox") }),
        ("run", { _ = try await workspace.run(run) }),
        ("runFacts", { _ = try await workspace.runFacts(run: run) }),
        ("ledger", { _ = try await workspace.ledger(from: 49_000, limit: 50) }),
        ("knowledge", { _ = try await workspace.knowledge(steward: "st_inbox") }),
        ("memory", { _ = try await workspace.memory(steward: "st_inbox") }),
        ("impact", { _ = try await workspace.impact(steward: "st_inbox") }),
        ("overviewFindings", { _ = try await workspace.overviewFindings(steward: "st_inbox") }),
    ]
    let budget = perfBudget(.milliseconds(20))
    for (name, read) in reads {
        let took = try await bestWarm(of: 5, read)
        #expect(took < budget, "warm \(name) took \(took) (budget \(budget))")
    }
}

/// The best of `count` warm calls (after one to warm up), so one slow call does not count.
func bestWarm(of count: Int, _ read: () async throws -> Void) async throws -> Duration {
    try await read()
    let clock = ContinuousClock()
    var best = Duration.seconds(60)
    for _ in 0..<count {
        let start = clock.now
        try await read()
        best = min(best, clock.now - start)
    }
    return best
}

/// A timing budget that holds on a loaded machine: when the 1-minute load average exceeds
/// twice the core count, the budget is ten times larger (and a note says so), so a busy host
/// slows the check down instead of failing it; a real regression still shows as 10x.
func perfBudget(_ base: Duration) -> Duration {
    var load = [0.0, 0.0, 0.0]
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    guard getloadavg(&load, 3) > 0, load[0] > 2 * cores else { return base }
    print(
        "perf budget: load \(Int(load[0])) > 2 x \(Int(cores)) cores; budget \(base) x 10")
    return base * 10
}
