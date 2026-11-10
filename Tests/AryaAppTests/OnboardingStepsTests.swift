import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let steward = "st_new"

/// A steward just created from the wizard: a charter whose inbox can list past items, nothing
/// rehearsed and nothing marked ready.
func onboardingEvents(rehearsed passed: Int? = nil, cases: Int = 4) -> [FeatureEvent] {
    var log = FeatureEventBuilder(start: now.addingTimeInterval(-3600))
    let charter: FeatureJSON = [
        "name": "Support inbox triage", "outcome": "Every new message is routed within an hour",
        "metric": ["name": "routed_within_1h", "target": 0.95, "direction": "up"],
        "bindings": [["id": "inbox", "kind": "mcp", "read": ["search", "get", "history"]]],
        "policy": ["default": "ask"],
    ]
    log.add(
        "steward.created", steward: steward, actor: .localUser, ["charter": charter, "version": 1])
    if let passed {
        log.add(
            "rehearsal.started", steward: steward,
            ["rehearsal": "rh_1", "charterVersion": 1, "cases": .number(Double(cases))])
        log.add(
            "rehearsal.finished", steward: steward,
            ["rehearsal": "rh_1", "passed": .number(Double(passed))])
    }
    return log.events
}

func onboardingQueue(total: Int, reviewed: Int) -> FeatureReviewQueue {
    FeatureReviewQueue(
        casebookVersion: "history@v1", rehearsal: nil,
        progressText: "\(reviewed) of \(total) reviewed", total: total, reviewed: reviewed,
        next: reviewed < total
            ? FeatureReviewQueue.Item(
                id: "case-0001", input: "Customer asks about a double charge",
                wouldHave: "label billing, route billing", personDid: "route refunds",
                matches: false, difference: "It would route to billing; you sent it to refunds.",
                source: "inbox history, Oct 14", status: "pending") : nil)
}

/// A new steward starts at learning, offering the inbox's history import.
@Test func newStewardStartsByLearningFromPastWork() {
    let steps = OnboardingSteps.build(events: onboardingEvents(), steward: steward, queue: nil)
    #expect(steps.current == .learn)
    #expect(steps.historyBindings == ["inbox"])
    #expect(steps.steps[0].detail == "Import past items from inbox.")
    #expect(!steps.steps.contains { $0.done })
}

/// Imported but not reviewed: the review queue is the current step.
@Test func importedHistoryMovesToReview() {
    let steps = OnboardingSteps.build(
        events: onboardingEvents(), steward: steward,
        queue: onboardingQueue(total: 40, reviewed: 12))
    #expect(steps.current == .review)
    #expect(steps.steps[0].detail == "40 past items in casebook history@v1")
    #expect(steps.steps[1].detail == "12 of 40 reviewed")
}

/// Reviewed and rehearsed with every case passing: Mark ready is offered with the rehearsal.
@Test func passingRehearsalOffersMarkReady() {
    let steps = OnboardingSteps.build(
        events: onboardingEvents(rehearsed: 4), steward: steward,
        queue: onboardingQueue(total: 4, reviewed: 4))
    #expect(steps.current == .live)
    #expect(steps.passed)
    #expect(steps.rehearsal == "rh_1")
    #expect(steps.charterVersion == 1)
    let failing = OnboardingSteps.build(
        events: onboardingEvents(rehearsed: 3), steward: steward,
        queue: onboardingQueue(total: 4, reviewed: 4))
    #expect(!failing.passed)
}
