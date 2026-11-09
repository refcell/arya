import Arya
import Foundation
import Testing

@testable import AryaApp

@MainActor @Suite struct RailOrderTests {
    func loadedModel() async -> AppModel {
        let model = AppModel(source: ShellPreviewWorkspace())
        await model.refresh()
        return model
    }

    @Test func runsNestUnderTheSelectedStewardOnly() async {
        let model = await loadedModel()
        let items = RailOrder.items(
            stewards: model.stewards, runs: model.runs, selected: "st_triage")
        #expect(
            items == [
                .steward("st_digest"), .steward("st_spend"), .steward("st_triage"),
                .run("run_0002", steward: "st_triage"), .run("run_0001", steward: "st_triage"),
                .run("run_0000", steward: "st_triage"), .approvals,
            ])
    }

    @Test func arrowsWalkTheRailAndStopAtTheEnds() async {
        let model = await loadedModel()
        var navigation = model.navigation
        func step(_ offset: Int) {
            let items = RailOrder.items(
                stewards: model.stewards, runs: model.runs, selected: navigation.steward)
            if let next = RailOrder.step(
                from: RailOrder.current(navigation), by: offset, in: items)
            {
                navigation.select(next)
            }
        }
        #expect(RailOrder.current(navigation) == .steward("st_digest"))
        step(-1)
        #expect(RailOrder.current(navigation) == .steward("st_digest"))
        step(1)
        step(1)
        // Selecting the spend watcher nests its run, so the walk passes through it.
        #expect(RailOrder.current(navigation) == .run("run_7", steward: "st_spend"))
        step(1)
        #expect(RailOrder.current(navigation) == .steward("st_triage"))
        step(1)
        #expect(RailOrder.current(navigation) == .run("run_0002", steward: "st_triage"))
        for _ in 0..<5 { step(1) }
        #expect(RailOrder.current(navigation) == .approvals)
    }

    @Test func emptyRailHasOnlyApprovals() {
        let items = RailOrder.items(stewards: [], runs: [:], selected: nil)
        #expect(items == [.approvals])
        #expect(RailOrder.step(from: nil, by: 1, in: items) == .approvals)
    }
}

@MainActor @Suite struct ApprovalsCountTests {
    @Test func storeCountMatchesTheQueue() async {
        let now = ShellPreviewWorkspace.referenceDate
        let store = FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now)
        await store.reload()
        let queue = ApprovalQueue.build(events: store.events)
        #expect(StoreApprovalsRow.pending(in: store) == queue.pending.count)
    }
}
