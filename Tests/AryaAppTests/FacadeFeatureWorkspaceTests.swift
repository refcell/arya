import Arya
import Foundation
import Testing

@testable import AryaApp

@Suite struct FacadeFeatureWorkspaceTests {
    @Test func ledgerEntriesBecomeFeatureEvents() {
        let entry = LedgerEntry(
            seq: 7, id: "evt_7", at: ShellPreviewWorkspace.referenceDate,
            type: "approval.requested", steward: "st_triage", run: "run_0002",
            actorKind: "steward", actorID: "st_triage",
            payload: #"{"approval":"ap_1","action":{"id":"a1","kind":"close_issue"}}"#)
        let event = FacadeFeatureWorkspace.event(entry)
        #expect(event.seq == 7 && event.type == "approval.requested")
        #expect(event.actor == FeatureActor(kind: .steward, id: "st_triage"))
        #expect(event.payload["approval"]?.string == "ap_1")
        #expect(event.payload["action"]?["kind"]?.string == "close_issue")
    }

    @Test func badPayloadsAndActorsDegradeQuietly() {
        let entry = LedgerEntry(
            seq: 1, id: "evt_1", at: ShellPreviewWorkspace.referenceDate, type: "x",
            actorKind: "robot", actorID: "r", payload: "not json")
        let event = FacadeFeatureWorkspace.event(entry)
        #expect(event.payload == .null)
        #expect(event.actor.kind == .system)
    }

    @Test func writesGoThroughTheFacade() async throws {
        let source = ShellPreviewWorkspace()
        let workspace = FacadeFeatureWorkspace(source: source)
        let before = try await workspace.events().count
        try await workspace.record(.approve(approval: "ap_1"))
        let events = try await workspace.events()
        #expect(events.count == before + 1)
        #expect(events.last?.type == "approval.granted")
        #expect(await source.approvals(includeDecided: false).map(\.id) == ["ap_2"])
        #expect(try await workspace.verify() == .intact(events: before + 1))
    }

    @Test func changesFollowTheLedger() async throws {
        let source = ShellPreviewWorkspace()
        var iterator = FacadeFeatureWorkspace(source: source).changes().makeAsyncIterator()
        // Three replayed creation events, then the new run.
        for _ in 0..<3 { _ = await iterator.next() }
        await source.startRun(
            RunSummary(
                id: "run_9", steward: "st_spend", trigger: "manual", charterVersion: 1,
                status: .running, startedAt: ShellPreviewWorkspace.referenceDate))
        #expect(await iterator.next() != nil)
    }
}
