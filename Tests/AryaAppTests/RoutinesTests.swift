import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

private func routine() throws -> RoutineItem {
    try #require(RoutineList.build(events: PreviewFixtures.triage(now: now)).routines.first)
}

@Test func routinesTrackLiveVersionAndHistory() throws {
    let item = try routine()
    #expect(item.name == PreviewFixtures.routineName)
    #expect(item.live == PreviewFixtures.routineV1)
    #expect(item.versions == [PreviewFixtures.routineV1, PreviewFixtures.routineV2])
    #expect(item.history.map(\.kind) == [.proposed, .promoted, .proposed])
    #expect(RoutinesText.live(item) == "live 1a2b3c")
    #expect(
        RoutinesText.history(item.history[2])
            == "Proposed 4d5e6f by st_triage: Label duplicates directly")
    #expect(RoutinesText.history(item.history[1]) == "Promoted 1a2b3c by arya")
    let pair = try #require(item.defaultComparison)
    #expect(pair.old == PreviewFixtures.routineV1)
    #expect(pair.new == PreviewFixtures.routineV2)
}

@Test func retiringTheLiveVersionLeavesNoLiveVersion() {
    var log = FeatureEventBuilder(start: now)
    log.add("routine.proposed", ["name": "r", "version": "sha256:aa"])
    log.add("routine.promoted", ["name": "r", "version": "sha256:aa"])
    log.add("routine.retired", ["name": "r", "version": "sha256:aa", "reason": "unused"])
    let item = RoutineList.build(events: log.events).routines[0]
    #expect(item.live == nil)
    #expect(RoutinesText.live(item) == "not live")
    #expect(item.defaultComparison == nil)
    #expect(RoutinesText.history(item.history[2]) == "Retired aa by st_triage: unused")
}

@Test func lineDiffMarksAddedAndRemovedLines() {
    let diff = LineDiff.unified(
        old: "a\nb\nc\n", new: "a\nc\nd\n", oldLabel: "r 1", newLabel: "r 2")
    #expect(diff == "--- r 1\n+++ r 2\n@@ -1,3 +1,3 @@\n a\n-b\n c\n+d")
    #expect(LineDiff.unified(old: "same\n", new: "same\n", oldLabel: "x", newLabel: "y").isEmpty)
    #expect(LineDiff.edits([], ["x"]) == [.added("x")])
    #expect(LineDiff.edits(["x"], []) == [.removed("x")])
}

@Test func loaderDiffsVersionsFromTheWorkspace() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let item = try routine()
    let state = await RoutineDiffLoader.load(
        workspace, item: item, old: PreviewFixtures.routineV1, new: PreviewFixtures.routineV2)
    guard case .diff(let text) = state else {
        Issue.record("expected a diff, got \(state)")
        return
    }
    #expect(text.hasPrefix("--- label-duplicates 1a2b3c\n+++ label-duplicates 4d5e6f"))
    #expect(text.contains("+tracker label duplicate"))
    let same = await RoutineDiffLoader.load(
        workspace, item: item, old: PreviewFixtures.routineV1, new: PreviewFixtures.routineV1)
    #expect(same == .identical)
    let missing = await RoutineDiffLoader.load(
        workspace, item: item, old: "sha256:gone", new: PreviewFixtures.routineV1)
    #expect(missing == .missing(version: "sha256:gone"))
}

/// A workspace without routine bodies, like the facade today.
private struct NoBodies: FeatureWorkspace {
    func events() async throws -> [FeatureEvent] { [] }
    func record(_ write: FeatureWrite) async throws -> [FeatureEvent] { [] }
    func verify() async throws -> FeatureVerifyResult { .intact(events: 0) }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@Test func loaderReportsUnavailableBodies() async throws {
    let state = await RoutineDiffLoader.load(NoBodies(), item: try routine(), old: "a", new: "b")
    #expect(state == .failed("This workspace cannot show routine bodies yet."))
}
