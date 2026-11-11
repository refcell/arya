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

/// The shared seed made from today's seed inputs (the stamp `etc/scripts/demo-current.sh`
/// computes), or nil when no worktree has seeded them yet today.
private func currentDemoSeed() -> URL? {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let script = """
        cd "$(git rev-parse --show-toplevel)" && { date +%F; find etc/scripts/demo.sh \\
          etc/examples Sources/AryaDemo Sources/Arya/Seeding.swift -type f -print0 | sort -z |
          xargs -0 shasum -a 256; } | shasum -a 256 | cut -d' ' -f1
        echo "$(cd "$(git rev-parse --git-common-dir)" && pwd)/arya-demo-homes"
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", script]
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    guard process.terminationStatus == 0, lines.count == 2 else { return nil }
    let seed = URL(fileURLWithPath: lines[1]).appendingPathComponent(lines[0])
    let stamp = seed.appendingPathComponent(".seed").path
    return FileManager.default.fileExists(atPath: stamp) ? seed : nil
}

/// The busy seeded home's checks, one at a time: each copies the 26 MB seed and folds it, so
/// running them together starves the timing tests.
@Suite(.serialized) struct BusyDemoHome {
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

    /// Today's spend is never blank on the busy demo home: the fleet spent something today and
    /// so did the live steward, at any hour of seeding (review #26: every COST TODAY read "—"
    /// after midnight, when only the cost-free example scripts had run today).
    @Test func busyDemoHomeReadsEveryConnectorsHistory() async throws {
        guard let seed = currentDemoSeed() else {
            print("busy demo home: no seed from today's inputs yet; just snapshot to check history")
            return
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-demo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: seed, to: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = try await Workspace.open(home: home)
        let statuses = try await workspace.ingestion()
        #expect(statuses.count >= 11, "\(statuses.map(\.line))")
        for status in statuses {
            let who = "\(status.steward) \(status.line)"
            #expect(status.records > 0 && status.passes >= 2 && status.complete, "\(who)")
            #expect(status.lastError == nil, "\(who)")
        }
        // Yesterday's pass read only what came in since the first (a history longer than one
        // page also stored a cursor to start from).
        #expect(statuses.filter { $0.lastAdded > 0 }.count >= 11)
        #expect(statuses.contains { $0.cursor != nil })
        // The triage inbox holds its export (25 records with what people chose) too.
        let triage = statuses.filter { $0.steward == "st_triage" }
        #expect(triage.first { $0.connection == "inbox" }.map { $0.records >= 25 } == true)
        for steward in try await workspace.stewards() {
            let systems = try await workspace.onboardingState(steward: steward.id).steps[0]
            #expect(systems.done && systems.count == systems.total, "\(systems.detail)")
        }
    }

    @Test func busyDemoHomeHasSpendToday() async throws {
        guard let seed = currentDemoSeed() else {
            print("busy demo home: no seed from today's inputs yet; just snapshot to check spend")
            return
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-demo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: seed, to: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = try await Workspace.open(home: home)
        let today = try await workspace.runs().filter {
            Calendar.current.isDateInToday($0.startedAt)
        }
        let fleet = today.reduce(0) { $0 + $1.costMicros }
        let lead = today.filter { $0.steward == "st_lead_follow_up" }.reduce(0) {
            $0 + $1.costMicros
        }
        #expect(fleet > 0, "fleet spent nothing today over \(today.count) runs")
        #expect(lead > 0, "the live steward spent nothing today")
    }

    /// Every active steward on the busy demo home reads like real work (review VC42): its
    /// outcome has data, its primary metric has at least five daily readings in the last week,
    /// and at most two of its live runs failed in the last seven days (the seeded bad week is
    /// three weeks back). A seed whose runs fail (a charter limit, a broken script) trips it.
    @Test func busyDemoHomeOutcomesHaveReadingsAndFewFailures() async throws {
        guard let seed = currentDemoSeed() else {
            print("busy demo home: no seed from today's inputs yet; just snapshot to check")
            return
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-demo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: seed, to: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = try await Workspace.open(home: home)
        for steward in try await workspace.stewards() where steward.status == .active {
            let outcome = try await workspace.outcome(steward: steward.id, windows: 7)
            #expect(outcome.status != .noData, "\(steward.id): no data")
            // Refunds and digest follow their history files' cadence (every two to three days).
            let readings = outcome.trend.filter { $0.value != nil }.count
            let sparse = ["st_refunds", "st_digest"].contains(steward.id)
            #expect(readings >= (sparse ? 2 : 5), "\(steward.id): \(readings) daily readings of 7")
            let history = try await workspace.runHistory(steward: steward.id)
            #expect(history.failed <= 2, "\(steward.id): \(history.line)")
            let overBudget = try await workspace.runs(steward: steward.id)
                .filter { $0.failureReason == "budget" }.count
            #expect(overBudget == 0, "\(steward.id): \(overBudget) runs failed on budget")
            // Its newest rehearsal of the live charter passes at least half its cases, and no
            // case failed on budget (VC42: every case "would do nothing" at a 0 budget).
            if let rehearsal = try await workspace.rehearsals(steward: steward.id)
                .filter({ $0.charterVersion != 0 }).max(by: { $0.id < $1.id })
            {
                #expect(
                    rehearsal.passed * 2 >= rehearsal.total,
                    "\(steward.id): rehearsal \(rehearsal.passed)/\(rehearsal.total) passed")
                let budget = rehearsal.cases.filter { $0.notes.joined().contains("budget") }
                #expect(budget.isEmpty, "\(steward.id): \(budget.count) cases failed on budget")
            }
            let findings = try await workspace.overviewFindings(steward: steward.id)
            for finding in findings where finding.text.hasSuffix("failed this week") {
                #expect(
                    finding.text.hasPrefix("\(history.failed) "),
                    "\(finding.text) vs \(history.line)")
            }
        }
    }

    /// A copy of the shared seed whose adapter profiles point at the copy and this build's fake
    /// adapter, so it can run like `just snapshot`'s home; nil without a seed or the adapter.
    private func runnableDemoHome() throws -> URL? {
        // The seed from today's inputs when there is one (its scripts match this build).
        guard let seed = currentDemoSeed() ?? sharedDemoHome() else { return nil }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let adapter = root.appendingPathComponent(".build/out/Products/Debug/arya-fake-adapter")
        guard FileManager.default.isExecutableFile(atPath: adapter.path) else { return nil }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-demo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: seed, to: home)
        let profiles = home.appendingPathComponent("adapters.json")
        var text = try String(contentsOf: profiles, encoding: .utf8)
        text = text.replacingOccurrences(
            of: #""[^"]*/\.build/demo-home/"#, with: "\"\(home.path)/", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #""[^"]*/arya-fake-adapter""#, with: "\"\(adapter.path)\"",
            options: .regularExpression)
        try text.write(to: profiles, atomically: true, encoding: .utf8)
        // The live lead run's last step holds for 30 minutes (for the snapshot); cap every pause.
        for script in try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent("demo"), includingPropertiesForKeys: nil)
        where script.pathExtension == "json" {
            let body = try String(contentsOf: script, encoding: .utf8)
            let capped = body.replacingOccurrences(
                of: #""sleepMs"\s*:\s*[0-9]{5,}"#, with: "\"sleepMs\": 1500",
                options: .regularExpression)
            if capped != body { try capped.write(to: script, atomically: true, encoding: .utf8) }
        }
        return home
    }

    /// Thread rows of a run, counted from one cached state: tool calls by the TOOLS tab's
    /// precedence (`runFacts.toolCalls`), proposed actions, and messages.
    private func threadRows(_ workspace: Workspace, run: String) async throws -> (Int, RunFacts) {
        let state = try workspace.facadeState()
        let id = RunID(unchecked: run)
        let record = try #require(state.runs.all.first { $0.id == id })
        let facts = await workspace.facts(record, state: state, now: Date(), timeZone: .current)
        let messages = (state.byRun[id] ?? []).flatMap { LiveTally.steps($0, run: id) }
            .filter { $0.kind == "message" }.count
        return (facts.toolCalls + facts.actionsProposed + messages, facts)
    }

    /// One step definition on the busy home's actual runs (review #20): the live lead follow-up
    /// run `just snapshot` starts, while it runs and once it finished, and seeded finished runs.
    @Test(.enabled(if: sharedDemoHome() != nil, "no shared seeded demo home in this clone"))
    func busyDemoHomeLiveAndFinishedRunsCountTheirThreadRows() async throws {
        guard let home = try runnableDemoHome() else { return }
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = try await Workspace.open(
            home: home, environment: ProcessInfo.processInfo.environment)
        let run = Task {
            try await workspace.startRun(
                steward: "st_lead_follow_up",
                input: "LEAD-LIVE: Pricing question from a 200-seat team")
        }
        var checkedLive = false
        var liveRun: String?
        for _ in 0..<600 {
            if let live = try await workspace.liveRuns().first(where: {
                $0.run.steward == "st_lead_follow_up"
            }), live.stepCount > 0 {
                let (rows, facts) = try await threadRows(workspace, run: live.run.id)
                if facts.status == "running" {
                    #expect(facts.stepIndex == rows)
                    // A next step is pending: "4 of ~5", never "4 of ~4".
                    #expect(facts.estimatedSteps.map { $0 >= facts.stepIndex + 1 } ?? true)
                    checkedLive = true
                    liveRun = live.run.id
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Cost so far while it runs: the adapter's `run/cost` answer after its first message.
        var liveCost: Int?
        if let liveRun, currentDemoSeed() != nil {
            for _ in 0..<600 {
                let facts = try await workspace.runFacts(run: liveRun)
                guard facts?.status == "running" else { break }
                if let cost = facts?.costMicros, cost > 0 {
                    liveCost = cost
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(liveCost != nil, "the live run showed no cost so far while running")
        }
        let done = try await run.value
        #expect(liveRun == done.id)
        let (rows, finished) = try await threadRows(workspace, run: done.id)
        #expect(finished.stepIndex == rows)
        #expect(finished.estimatedSteps == nil)
        var shown = 0
        for await update in workspace.observe(run: done.id) {
            shown += update.steps.filter(\.isVisible).count
        }
        #expect(shown == rows)
        if !checkedLive { Issue.record("the live run never showed a step while running") }

        for summary in try await workspace.runs().filter({ $0.parent == nil }).prefix(40) {
            let (rows, facts) = try await threadRows(workspace, run: summary.id)
            #expect(facts.stepIndex == rows, "\(summary.id)")
        }
    }

    /// Impact never claims more windows with actions than the period has (review #20).
    @Test(.enabled(if: sharedDemoHome() != nil, "no shared seeded demo home in this clone"))
    func busyDemoHomeImpactWindowsNeverExceedThePeriod() async throws {
        let seed = try #require(sharedDemoHome())
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-demo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: seed, to: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = try await Workspace.open(home: home)
        var rows = 0
        for steward in try await workspace.stewards() {
            guard let impact = try await workspace.impact(steward: steward.id) else { continue }
            let windows = try #require(impact.windows)
            for row in impact.rows {
                rows += 1
                #expect(row.windows <= windows, "\(steward.name): \(row.line)")
                #expect(row.line.contains("of \(windows) windows"), "\(row.line)")
            }
        }
        #expect(rows > 0)
    }
}
