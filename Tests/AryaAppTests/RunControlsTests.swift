import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let steward = PreviewFixtures.steward

@Test func runNowRecordsAManualRunByThePerson() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let written = try await workspace.record(.startRun(steward: steward, input: "ISSUE-7"))
    #expect(written.map(\.type) == ["run.started"])
    #expect(written[0].actor == .localUser)
    #expect(written[0].payload["trigger"] == "manual")
    #expect(written[0].payload["input"] == "ISSUE-7")
    let run = try #require(written[0].run)
    #expect(RunStream.build(events: await workspace.events(), run: run).status == .running)
}

@Test func rehearseStartsARehearsalOfTheLiveCharter() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let written = try await workspace.record(.rehearse(steward: steward, casebook: nil))
    #expect(written.map(\.type) == ["rehearsal.started"])
    #expect(written[0].payload["charterVersion"] == 1)
    #expect(written[0].payload["casebookVersion"] == .string(PreviewFixtures.casebook))
    #expect(written[0].payload["cases"] == 3)
    let list = RehearsalList.build(events: await workspace.events(), steward: steward)
    #expect(list.rehearsals.count == 2)
}

@Test func replayReportsMatchOrFirstDivergence() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let clean = try await workspace.replay(run: "run_0001")
    #expect(clean.divergences.isEmpty)
    #expect(ReplayText.summary(clean) == "Replayed \(clean.events) events with no divergence.")
    await workspace.markDivergent("run_0001")
    let diverged = try await workspace.replay(run: "run_0001")
    let first = try #require(diverged.divergences.first)
    #expect(first.field == "payload.output")
    let seq = first.seq ?? 0
    let expected =
        "Diverged at event \(diverged.events) of \(diverged.events) (\(first.type), seq \(seq)), "
        + "field payload.output."
    #expect(ReplayText.summary(diverged) == expected)
    await #expect(throws: FeatureReadError.self) { try await workspace.replay(run: "run_none") }
}

@Test func replayIsUnavailableWithoutAnEngine() async {
    struct Bare: FeatureWorkspace {
        func events() async throws -> [FeatureEvent] { [] }
        func record(_ write: FeatureWrite) async throws -> [FeatureEvent] { [] }
        func verify() async throws -> FeatureVerifyResult { .intact(events: 0) }
        func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }
    await #expect(throws: FeatureReadError.unavailable("replay")) {
        try await Bare().replay(run: "run_0001")
    }
}
