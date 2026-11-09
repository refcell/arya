import Arya
import AryaDesign
import Foundation
import SwiftUI
import Testing

@testable import AryaApp

@MainActor @Suite struct AppModelTests {
    @Test func refreshLoadsTheSampleWorkspace() async {
        let model = AppModel(source: ShellPreviewWorkspace())
        await model.refresh()
        #expect(model.stewards.map(\.id) == ["st_digest", "st_spend", "st_triage"])
        #expect(model.runs["st_triage"]?.map(\.id) == ["run_0002", "run_0001", "run_0000"])
        #expect(model.pendingApprovalCount == 2)
        #expect(model.approvals.map(\.id) == ["ap_2", "ap_1"])
        #expect(model.effort(for: "st_spend") == .low)
        #expect(model.navigation.steward == "st_digest")
        #expect(model.problem == nil)
    }

    @Test func runningStewardShowsTheLiveStatus() async {
        let model = AppModel(source: ShellPreviewWorkspace())
        await model.refresh()
        let triage = model.stewards.first { $0.id == "st_triage" }
        let paused = model.stewards.first { $0.id == "st_digest" }
        #expect(
            triage.map { StatusMapping.status(of: $0, runs: model.runs["st_triage"] ?? []) }
                == .running)
        #expect(paused.map { StatusMapping.status(of: $0, runs: []) } == .paused)
    }

    @Test func approvingDropsThePendingCount() async {
        let model = AppModel(source: ShellPreviewWorkspace())
        await model.refresh()
        await model.approve("ap_1")
        #expect(model.pendingApprovalCount == 1)
        await model.deny("ap_1")
        #expect(model.problem?.contains("already decided") == true)
    }

    @Test func effortChangesAreWritten() async {
        let source = ShellPreviewWorkspace()
        let model = AppModel(source: source)
        await model.refresh()
        await model.setEffort(.high, steward: "st_spend")
        #expect(model.effort(for: "st_spend") == .high)
        #expect(await source.efforts()["st_spend"] == "high")
    }

    @Test func liveUpdatesFollowTheLedger() async throws {
        let source = ShellPreviewWorkspace()
        let model = AppModel(source: source)
        await model.refresh()
        let watcher = Task { await model.watch() }
        defer { watcher.cancel() }
        // The stream replays the three creation events first.
        try await waitUntil { model.nextSeq == 4 }
        await source.startRun(
            RunSummary(
                id: "run_8", steward: "st_spend", trigger: "manual", charterVersion: 1,
                status: .running, startedAt: ShellPreviewWorkspace.referenceDate))
        try await waitUntil { model.runs["st_spend"]?.first?.id == "run_8" }
        #expect(model.live == .watching)
    }

    @Test func aRealHomeReportsWhatIsNotAvailableYet() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = AppSession()
        await session.open(.home(home))
        let model = try #require(session.model)
        await model.refresh()
        #expect(model.loaded)
        if let problem = model.problem {
            #expect(problem.hasPrefix("This workspace cannot do that yet"))
        }
    }

    @Test(arguments: [false, true])
    func theShellRenders(dark: Bool) async throws {
        for empty in [false, true] {
            let model = AppModel(source: ShellPreviewWorkspace(empty: empty))
            await model.refresh()
            for destination in [model.navigation.destination, .approvals] {
                model.navigation.destination = destination
                let view = HStack(spacing: 0) {
                    RailView(model: model, now: ShellPreviewWorkspace.referenceDate).frame(
                        width: 240)
                    MainPane(model: model)
                }
                .frame(width: 1120, height: 720)
                .environment(\.colorScheme, dark ? .dark : .light)
                let image = ImageRenderer(content: view).nsImage
                #expect((image?.size.width ?? 0) == 1120)
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
