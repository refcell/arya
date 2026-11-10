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

/// The workspace's onboarding read for the fixture steward: `done` names the finished steps.
func onboardingRead(
    done: Set<String>, notes: [FeatureOnboarding.Note] = [],
    gate: FeatureOnboarding.Gate? = nil
) -> FeatureOnboarding {
    let details = [
        ("systems", "Read its systems", "Read 1 of 2 systems: inbox."),
        ("people", "Find its people", "Knows 3 people: person:ana, person:ben, person:cy."),
        ("processes", "Learn its processes", "Learned 1 routine: refund-routing."),
        ("notes", "Write context notes", "Wrote 4 notes about its people and systems."),
        ("history", "Import history", "Imported 40 cases from history."),
        ("review", "Review what it would do", "12 of 40 reviewed"),
        ("ready", "Ready to go live", "Not ready: never rehearsed on past work."),
    ]
    return FeatureOnboarding(
        steps: details.map {
            FeatureOnboarding.Step(
                key: $0.0, title: $0.1, done: done.contains($0.0),
                detail: done.contains($0.0) || $0.0 == "review" || $0.0 == "ready"
                    ? $0.2 : "Nothing yet for \($0.0).")
        },
        summary: "\(done.count) of 7 steps done", notes: notes, onboardedAt: nil, gate: gate)
}

let onboardingNotes = [
    FeatureOnboarding.Note(about: "person:ana", text: "Support lead; owns refunds over 200."),
    FeatureOnboarding.Note(about: "person:ben", text: "Billing; answers double-charge questions."),
    FeatureOnboarding.Note(about: "inbox", text: "Queue 'vip' routes to person:ana first."),
    FeatureOnboarding.Note(about: "inbox", text: "Refund requests over 30 days go to billing."),
]

/// A new steward starts by reading its systems, with Run onboarding and no notes.
@Test func newStewardStartsByReadingItsSystems() {
    let steps = OnboardingSteps.build(
        onboarding: onboardingRead(done: []), events: onboardingEvents(), steward: steward)
    #expect(steps.current == .systems)
    #expect(steps.notes.isEmpty)
    #expect(steps.steps[0].detail == "Nothing yet for systems.")
    #expect(steps.steps[1].detail == "Import past items from inbox.")
    #expect(!steps.steps.contains { $0.done })
}

/// Onboarded and imported: the notes show and the review queue is the current step.
@Test func onboardedStewardMovesToReview() {
    let steps = OnboardingSteps.build(
        onboarding: onboardingRead(
            done: ["systems", "people", "processes", "notes", "history"], notes: onboardingNotes),
        events: onboardingEvents(), steward: steward)
    #expect(steps.current == .review)
    #expect(steps.notes.count == 4)
    #expect(
        steps.steps[0].detail
            == "Wrote 4 notes about its people and systems. "
            + "Knows 3 people: Ana, Ben, Cy.")
    #expect(steps.notes[2] == .init(about: "inbox", text: "Queue 'vip' routes to Ana first."))
    #expect(steps.notes[0].about == "Ana")
    #expect(steps.steps[1].detail == "Imported 40 cases from history.")
    #expect(steps.steps[2].detail == "12 of 40 reviewed")
}

/// Mark ready follows the go-live gate: its sentence while it fails, enabled once it passes.
@Test func markReadyFollowsTheGoLiveGate() {
    let all: Set = ["systems", "people", "processes", "notes", "history", "review"]
    let failing = OnboardingSteps.build(
        onboarding: onboardingRead(
            done: all,
            gate: .init(ready: false, summary: "Not ready: 4 more agreed reviews needed.")),
        events: onboardingEvents(rehearsed: 4), steward: steward)
    #expect(failing.current == .live)
    #expect(!failing.canMarkReady)
    #expect(failing.steps[3].detail == "Not ready: 4 more agreed reviews needed.")
    let passing = OnboardingSteps.build(
        onboarding: onboardingRead(
            done: all, gate: .init(ready: true, summary: "Ready to go live: 10 agreed.")),
        events: onboardingEvents(rehearsed: 4), steward: steward)
    #expect(passing.canMarkReady)
    #expect(passing.rehearsal == "rh_1")
    let unrehearsed = OnboardingSteps.build(
        onboarding: onboardingRead(done: all, gate: .init(ready: true, summary: "")),
        events: onboardingEvents(), steward: steward)
    #expect(!unrehearsed.canMarkReady)
}
