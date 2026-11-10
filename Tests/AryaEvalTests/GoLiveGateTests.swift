import AryaCore
import Testing

@testable import AryaEval

private func queue(total: Int, agreed: Int) -> ReviewQueueView {
    ReviewQueueView(
        steward: "st_inbox", casebook: "history", casebookVersion: "v", rehearsal: nil,
        items: [], total: total, reviewed: agreed, agreed: agreed, corrected: 0, skipped: 0,
        matching: 0, progressText: "", next: nil)
}

private func readiness(ready: Bool) -> ReadinessReport {
    ReadinessReport(
        steward: StewardID(unchecked: "st_inbox"), charterVersion: 1, ready: ready, summary: "",
        markedReady: false,
        reasons: ready ? [] : [ReadinessReason(code: "leaks", message: "2 cases leaked")],
        rehearsal: nil, lastRehearsalAt: nil, passRate: 1, passed: 34, total: 34, threshold: 1,
        meanScore: 1, leaks: 0, regressions: [], correctionsOutstanding: 0)
}

private func checks(total: Int, scored: Int, passed: Int) -> LearnedChecksView {
    LearnedChecksView(
        steward: "st_inbox", version: 1, rehearsal: nil, results: [], total: total,
        scored: scored, passed: passed, added: [], removed: [], sentence: "")
}

/// Ready to go live needs N agreed reviews, a passing live rehearsal, and green checks; each
/// unmet condition says what is missing, in one sentence the onboarding screen shows.
@Test func goLiveNeedsAgreementsARehearsalAndGreenChecks() {
    let ready = GoLiveGate.evaluate(
        steward: "st_inbox", review: queue(total: 30, agreed: 10),
        readiness: readiness(ready: true), checks: checks(total: 8, scored: 8, passed: 8))
    #expect(ready.ready && ready.conditions.map(\.key) == ["review", "rehearsal", "checks"])
    #expect(
        ready.summary
            == "Ready to go live: 10 agreed, 34/34 passed, no regressions, checks green.")

    let short = GoLiveGate.evaluate(
        steward: "st_inbox", review: queue(total: 30, agreed: 6),
        readiness: readiness(ready: false), checks: checks(total: 3, scored: 3, passed: 1))
    #expect(!short.ready && short.conditions.allSatisfy { !$0.met })
    #expect(short.conditions[0].detail == "6 of 10 agreed reviews")
    #expect(
        short.summary
            == "Not ready: 4 more agreed reviews needed; 2 cases leaked; 2 checks fail.")

    // A queue smaller than the ask needs every case agreed; no history cannot pass.
    let small = GoLiveGate.evaluate(
        steward: "st_inbox", review: queue(total: 3, agreed: 3),
        readiness: readiness(ready: true), checks: checks(total: 3, scored: 2, passed: 2))
    #expect(small.agreedNeeded == 3 && small.conditions[0].met && !small.conditions[2].met)
    #expect(small.conditions[2].detail == "1 check not rehearsed yet")
    let none = GoLiveGate.evaluate(
        steward: "st_inbox", review: nil, readiness: readiness(ready: true), checks: nil)
    #expect(none.summary == "Not ready: import history to review; no checks yet.")
}
