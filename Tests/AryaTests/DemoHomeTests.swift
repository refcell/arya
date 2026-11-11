import AryaCore
import AryaLedger
import AryaRuntime
import Foundation
import Testing

@testable import Arya

/// The newest seeded demo home shared by this clone's worktrees
/// (`<git common dir>/arya-demo-homes/<stamp>`, written by `etc/scripts/demo-current.sh`), or
/// nil when none was seeded here.
private func sharedDemoHome() -> URL? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--git-common-dir"]
    process.currentDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !out.isEmpty else { return nil }
    let common = URL(
        fileURLWithPath: out, relativeTo: process.currentDirectoryURL
    ).standardizedFileURL
    let shared = common.appendingPathComponent("arya-demo-homes")
    let fm = FileManager.default
    let stamps =
        (try? fm.contentsOfDirectory(
            at: shared, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return stamps.filter { fm.fileExists(atPath: $0.appendingPathComponent(".seed").path) }
        .max {
            let a =
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b =
                (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a < b
        }
}

/// On the busy demo home, every run's tool count is the runtime's step records the TOOLS tab
/// lists (distinct step ids), including the run in progress when there is one.
@Test(.enabled(if: sharedDemoHome() != nil, "no shared seeded demo home in this clone"))
func busyDemoHomeRunFactsCountStepToolRecords() async throws {
    let seed = try #require(sharedDemoHome())
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-demo-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: seed, to: home)
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try await Workspace.open(home: home)

    var steps: [String: Set<String>] = [:]
    try workspace.reader.forEach { event in
        if let run = event.run, event.type == StepEventType.started,
            let id = event.payload["step"]?.stringValue
        {
            steps[run.rawValue, default: []].insert(id)
        }
    }
    #expect(!steps.isEmpty)
    let live = try await workspace.liveRuns().first?.run.id
    let checked = (live.map { [$0] } ?? []) + steps.keys.sorted().suffix(40)
    for run in checked {
        let facts = try #require(try await workspace.runFacts(run: run))
        #expect(facts.toolCalls == steps[run]?.count ?? 0, "run \(run)")
    }
}

/// Run-count bars on the busy home: each steward's 7 days sum to its top-level live runs
/// started in those days, and rehearsal bursts stay out of them.
@Test(.enabled(if: sharedDemoHome() != nil, "no shared seeded demo home in this clone"))
func busyDemoHomeRunBarsSumToRunsInThoseDays() async throws {
    let seed = try #require(sharedDemoHome())
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-demo-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: seed, to: home)
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try await Workspace.open(home: home)
    let utc = try #require(TimeZone(identifier: "UTC"))
    var fleet = 0
    for steward in try await workspace.stewards() {
        let history = try await workspace.runHistory(steward: steward.id, timeZone: utc)
        let from = try #require(history.days.first?.start)
        let expected = try await workspace.runs(steward: steward.id).filter {
            $0.parent == nil && $0.trigger != "case" && $0.startedAt >= from
        }.count
        #expect(history.days.count == 7)
        #expect(history.total == expected, "\(steward.name)")
        #expect(history.days.reduce(0) { $0 + $1.runs } == expected)
        fleet += history.total
    }
    #expect(try await workspace.runHistory(timeZone: utc).total == fleet)
}

/// One step definition (CEO): on the busy home, `runFacts.stepIndex` equals the visible rows
/// `observe(run:)` yields for the run's thread.
@Test(.enabled(if: sharedDemoHome() != nil, "no shared seeded demo home in this clone"))
func busyDemoHomeStepsAreTheVisibleThreadRows() async throws {
    let seed = try #require(sharedDemoHome())
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-demo-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: seed, to: home)
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try await Workspace.open(home: home)
    let runs = try await workspace.runs().filter { $0.parent == nil }.prefix(6)
    #expect(!runs.isEmpty)
    for run in runs {
        var rows = 0
        for await update in workspace.observe(run: run.id) {
            rows += update.steps.filter(\.isVisible).count
        }
        let facts = try #require(try await workspace.runFacts(run: run.id))
        #expect(facts.stepIndex == rows, "\(run.id)")
        #expect(try await workspace.visibleSteps(run: run.id) == rows)
        if facts.status != "running" { #expect(facts.estimatedSteps == nil) }
    }
}

/// On the busy demo home, every active steward has live runs (not just rehearsals) on at least
/// five of the last seven local days, so RUNS 7D reads as weeks of work, not one burst today.
@Test(.enabled(if: sharedDemoHome() != nil, "no shared seeded demo home in this clone"))
func busyDemoHomeHasRunsOnMostOfTheLastWeek() async throws {
    let seed = try #require(sharedDemoHome())
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-demo-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: seed, to: home)
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try await Workspace.open(home: home)
    // A paused steward does not run, and the refund and digest examples follow the cadence of
    // their history files (an order every two to three days), so they are not held to it.
    // Complete days only: early in the morning today has no runs yet.
    let examples: Set<String> = ["st_refunds", "st_digest"]
    for steward in try await workspace.stewards()
    where steward.status == .active && !examples.contains(steward.id) {
        let history = try await workspace.runHistory(steward: steward.id, days: 8)
        let busy = history.days.dropLast().filter { $0.runs > 0 }.count
        #expect(busy >= 5, "\(steward.id): runs on \(busy) of 7 days (\(history.line))")
        #expect(history.today < history.total, "\(steward.id): every run is today")
    }
}
