import Testing

@testable import AryaApp

private func credit(_ resolved: Int, _ reopened: Int, confidence: Double, lag: Double?)
    -> FeatureTrajectories.Credit
{
    let settled = resolved + reopened
    return FeatureTrajectories.Credit(
        id: "kind:label", axis: "kind", name: "label", resolved: resolved, reopened: reopened,
        pending: 0, rate: settled == 0 ? nil : Double(resolved) / Double(settled),
        confidence: confidence, medianLagDays: lag, line: "label")
}

/// Enough outcomes show resolved of settled, the lag, and a confidence level; sparse evidence
/// shows dashes and says how few outcomes there are.
@Test func whatWorkedRowsAndSparseEvidence() {
    let solid = credit(10, 2, confidence: 0.71, lag: 8.6)
    #expect(WhatWorkedText.outcome(solid) == "10/12" && WhatWorkedText.lag(solid) == "9d")
    #expect(WhatWorkedText.confidence(solid) == "high 0.71")
    let sparse = credit(2, 0, confidence: 0.34, lag: 0.4)
    #expect(WhatWorkedText.outcome(sparse) == "—" && WhatWorkedText.lag(sparse) == "<1d")
    #expect(WhatWorkedText.confidence(sparse) == "low confidence: 2 outcomes")
    #expect(WhatWorkedText.lag(credit(0, 0, confidence: 0, lag: nil)) == "—")
    #expect(WhatWorkedText.confidence(credit(1, 0, confidence: 0.2, lag: 1)).hasSuffix("1 outcome"))
    #expect(WhatWorkedText.level(0.4) == "medium" && WhatWorkedText.level(0.1) == "low")

    let worked = FeatureTrajectories(good: 4, bad: 1, pending: 2, sentence: "", credits: [])
    #expect(WhatWorkedText.tally(worked) == "4 good · 1 reopened · 2 open")
    let none = FeatureTrajectories(good: 0, bad: 0, pending: 0, sentence: "", credits: [])
    #expect(WhatWorkedText.tally(none) == "nothing graded yet")
}

@Test func goLiveGateTallyAndTitles() {
    let gate = FeatureGoLiveGate(
        ready: false, summary: "Not ready: 4 more agreed reviews needed.",
        conditions: [
            .init(key: "review", met: false, detail: "6 of 10 agreed reviews"),
            .init(key: "rehearsal", met: true, detail: "34/34 passed, no regressions"),
            .init(key: "checks", met: true, detail: "all 8 checks pass"),
        ])
    #expect(GoLiveGateText.tally(gate) == "2 of 3 met")
    #expect(
        gate.conditions.map { GoLiveGateText.title($0.key) }
            == ["Agreed reviews", "Rehearsal", "Learned checks"])
}
