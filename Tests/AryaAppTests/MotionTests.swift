import AppKit
import Arya
import AryaDesign
import Foundation
import SwiftUI
import Testing

@testable import AryaApp

/// Live motion must not keep offscreen renders from settling (snapshots, other lanes' renders).
@MainActor @Suite struct MotionTests {
    @Test func motionIsFrozenInTestProcesses() {
        #expect(AryaMotion.frozenByProcess)
        #expect(AryaMotion.isStill(reduceMotion: false))
    }

    @Test func liveRootRendersInBoundedTime() async throws {
        let now = FakeWorkspaceSource.referenceDate
        let model = AppModel(
            source: FakeWorkspaceSource(now: now),
            featureStore: FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now))
        await model.refresh()
        await model.featureStore?.reload()
        let steward = try #require(model.stewards.first)
        model.runs[steward.id, default: []].insert(
            RunSummary(
                id: "run_live", steward: steward.id, trigger: "schedule", charterVersion: 1,
                status: .running, startedAt: now.addingTimeInterval(-4)),
            at: 0)
        model.navigation.select(steward: steward.id)
        let clock = ContinuousClock()
        let start = clock.now
        let host = NSHostingView(rootView: RootView(model: model, now: { now }))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        #expect(clock.now - start < .seconds(20))
    }
}
