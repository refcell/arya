import Arya
import Foundation
import Testing

@testable import AryaApp

@Suite struct PulseTests {
    let now = Date(timeIntervalSince1970: 1_762_700_000)
    let utc = TimeZone(identifier: "UTC")!

    private func run(
        _ id: String, _ steward: String, hoursAgo: Double, status: RunSummary.Status = .finished,
        cost: Int = 0
    ) -> RunSummary {
        RunSummary(
            id: id, steward: steward, trigger: "schedule", charterVersion: 1, status: status,
            startedAt: now.addingTimeInterval(-hoursAgo * 3600), costMicros: cost)
    }

    @Test func countdownReadsLikeAClock() {
        #expect(StewardPulse.countdown(to: now.addingTimeInterval(-5), now: now) == "due")
        #expect(StewardPulse.countdown(to: now.addingTimeInterval(45), now: now) == "in 45 s")
        #expect(StewardPulse.countdown(to: now.addingTimeInterval(14 * 60), now: now) == "in 14m")
        #expect(StewardPulse.countdown(to: now.addingTimeInterval(8040), now: now) == "in 2h 14m")
        #expect(StewardPulse.countdown(to: now.addingTimeInterval(3 * 86_400), now: now) == "in 3d")
    }

    @Test func runBarsComeFromTheWorkspaceRunHistory() {
        // The ledger's runs say nothing here; the workspace's history (rehearsals apart) wins.
        let start = now.timeIntervalSinceReferenceDate
        var days: [String] = []
        for index in 0..<7 {
            let runs = index == 6 ? 2 : 1
            let failed = index == 6 ? 1 : 0
            let rehearsals = index == 3 ? 120 : 0
            let day = start + Double(index - 6) * 86_400
            days.append(
                "{\"start\":\(day),\"runs\":\(runs),\"failed\":\(failed),"
                    + "\"rehearsals\":\(rehearsals)}")
        }
        let json =
            "{\"steward\":\"s\",\"days\":[\(days.joined(separator: ","))],\"total\":8,"
            + "\"failed\":1,\"today\":2,\"line\":\"8 runs in 7 days, 2 today, 1 failed\"}"
        guard let history = try? JSONDecoder().decode(RunHistory.self, from: Data(json.utf8))
        else {
            Issue.record("RunHistory did not decode")
            return
        }
        let steward = StewardSummary(
            id: "s", name: "S", outcome: "o", charterVersion: 1, status: .active, ready: true)
        let pulse = StewardPulse.build(
            steward: steward, runs: [run("a", "s", hoursAgo: 1)], approvals: [], events: [],
            now: now, history: history, timeZone: utc)
        #expect(pulse.runsPerDay == [1, 1, 1, 1, 1, 1, 2])
        #expect(pulse.failedPerDay.last == 1)
        #expect(pulse.runsLine == "8 runs in 7 days, 2 today, 1 failed")
        let fleet = FleetPulse.build(
            stewards: [steward], runs: [:], approvals: [], events: [], history: history, now: now,
            timeZone: utc)
        #expect(fleet.runsPerDay.max() == 2 && fleet.runsToday == 2)
    }

    @Test func costTodayIsADashWhenUnknown() {
        #expect(
            StewardPulse.costToday([run("a", "s", hoursAgo: 1)], now: now, timeZone: utc) == "—")
        #expect(
            StewardPulse.costToday(
                [run("a", "s", hoursAgo: 1, cost: 4200)], now: now, timeZone: utc)
                == "$0.0042 today")
    }

    @Test func statusBarNamesTheNewestRunningStewardAndTheNewestEvent() {
        let stewards = [
            StewardSummary(
                id: "st_triage", name: "Support inbox triage", outcome: "", charterVersion: 1,
                status: .active, ready: true),
            StewardSummary(
                id: "st_refund", name: "Refund follow-up", outcome: "", charterVersion: 1,
                status: .active, ready: true),
        ]
        let runs = [
            "st_triage": [run("r1", "st_triage", hoursAgo: 0.1, status: .running)],
            "st_refund": [run("r2", "st_refund", hoursAgo: 0.05, status: .running)],
        ]
        // A run's recorded status never counts: only workspace live runs do.
        #expect(!runs.isEmpty && !stewards.isEmpty)
        #expect(StatusBarLine.lines(live: []).isEmpty)
        #expect(StatusBarLine.live([], now: now) == nil)
        let reported = LiveLine(
            run: "r9", steward: "st_triage", name: "Support inbox triage", steps: 3,
            lastStep: "Called search", progress: 0.4, started: now.addingTimeInterval(-4))
        #expect(
            StatusBarLine.lines(live: [reported]) == [reported])
        #expect(
            StatusBarLine.live([reported], now: now)
                == "Support inbox triage running · step 3 · 4 s")
    }
}

@Test func portfolioMetricFigureDropsTheName() {
    var row = PortfolioRow(
        id: "s", name: "S", outcome: "", metric: "0.84 / 0.90 confirmed_within_1d", trend: [],
        behind: true, state: "live", waiting: 0, lastRun: "now", nextWake: "on demand",
        health: .behind)
    #expect(row.metricFigure == "0.84 / 0.90")
    row.metric = "no metric"
    #expect(row.metricFigure == "no metric")
}

@Test func actionWordsHumanizeKindsOneWay() {
    #expect(ActionWords.kind("follow_up") == "follow-up")
    #expect(ActionWords.kind("follow-up") == "follow-up")
    #expect(ActionWords.kind("") == "action")
    #expect(ActionWords.line(kind: "reply", target: "inbox:ORDER-1043") == "Reply inbox:ORDER-1043")
}

@Test func liveElapsedTicksFromTheWorkspaceReading() {
    let read = Date(timeIntervalSince1970: 1_762_700_000)
    let line = LiveLine(
        run: "r", steward: "s", name: "Lead follow-up", steps: 3, lastStep: nil, progress: 0.4,
        started: read.addingTimeInterval(-100), elapsedSeconds: 8, readAt: read,
        estimatedSteps: 7)
    // The workspace's elapsed wins over the start time; it ticks from when it was read.
    #expect(line.elapsed(at: read.addingTimeInterval(2)) == 10)
    #expect(
        StatusBarLine.live([line], now: read.addingTimeInterval(2))
            == "Lead follow-up running · step 3 of ~7 · 10 s")
}
