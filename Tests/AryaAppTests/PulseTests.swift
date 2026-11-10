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
        #expect(
            StatusBarLine.live(stewards: stewards, runs: runs, events: [])
                == "Refund follow-up running · step 1 · +1 more")
        #expect(StatusBarLine.live(stewards: stewards, runs: [:], events: []) == nil)
    }
}
