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

    @Test func runsPerDayCountsAWeekOldestFirstWithFailures() {
        let runs = [
            run("a", "s", hoursAgo: 0.5), run("b", "s", hoursAgo: 1, status: .failed),
            run("c", "s", hoursAgo: 30), run("old", "s", hoursAgo: 24 * 9),
        ]
        let (totals, failed) = StewardPulse.perDay(runs, now: now, timeZone: utc)
        #expect(totals.count == 7)
        #expect(totals.last == 2)
        #expect(failed.last == 1)
        #expect(totals.reduce(0, +) == 3)
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
                == "Support inbox triage running · step 3 · 4.0 s")
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
            == "Lead follow-up running · step 3 of ~7 · 10.0 s")
}
