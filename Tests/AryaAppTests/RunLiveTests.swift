import Foundation
import Testing

@testable import AryaApp

@Test func liveRunShowsProgressAgainstTheStewardsUsualRun() throws {
    let now = FeatureTestClock.now
    let events = PreviewFixtures.live(now: now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.inProgressRun)
    #expect(stream.status == .running)
    let progress = try #require(stream.progress)
    #expect(progress.expected == 6)
    #expect(progress.text(now: now) == "\(progress.done) of ~6 steps · 4.2 s")
    #expect(progress.fraction > 0 && progress.fraction < 1)
}

@Test func theOpenToolCallIsTheRunningBlock() {
    let now = FeatureTestClock.now
    let events = PreviewFixtures.live(now: now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.inProgressRun)
    let work = RunWork.build(stream: stream, events: events)
    #expect(work.blocks.last?.title == "billing.order")
    #expect(work.blocks.last?.mark == .running)
    #expect(work.blocks.first?.mark == .ok)
}

@Test func finishedRunsHaveNoProgressAndNoHistoryReadsPlainly() {
    let now = FeatureTestClock.now
    let finished = RunStream.build(
        events: PreviewFixtures.triage(now: now), run: PreviewFixtures.finishedRun)
    #expect(finished.progress == nil)
    let lone = RunProgress(done: 3, expected: nil, started: now.addingTimeInterval(-2))
    #expect(lone.text(now: now) == "3 steps · 2.0 s")
}

@Test func runKeysMoveBetweenWorkSteps() {
    let now = FeatureTestClock.now
    let stream = RunStream.build(
        events: PreviewFixtures.live(now: now), run: PreviewFixtures.inProgressRun)
    let ids = stream.steps.filter { RunWork.isWork($0.kind) }.map(\.id)
    #expect(RunKeys.step(stream, from: nil, by: 1) == ids.first)
    #expect(RunKeys.step(stream, from: ids.first, by: 1) == ids.last)
    #expect(RunKeys.step(stream, from: ids.last, by: 1) == ids.last)
    #expect(RunKeys.action(for: "c") == .compose)
    #expect(RunKeys.action(for: "x") == nil)
}
