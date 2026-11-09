import AppKit
import Arya
import Foundation
import SwiftUI
import Testing

@testable import AryaApp

/// Renders the shell offscreen. `just screenshots` seeds the demo home, then sets
/// `ARYA_SCREENSHOTS_HOME` to it and `ARYA_SCREENSHOTS_DIR` to write PNGs for the README and
/// visual review. Without them the test renders the fake workspace and writes nothing.
@MainActor @Suite struct ScreenshotTests {
    @Test(arguments: ["light", "dark"])
    func shellScreenshots(scheme: String) async throws {
        let model = try await makeModel()
        await model.refresh()
        await model.featureStore?.reload()
        let steward = try #require(model.stewards.first { $0.id == "st_triage" })
        var shots: [(String, Destination, StewardTab)] = StewardTab.allCases.map {
            ($0.rawValue, .steward(steward.id), $0)
        }
        shots.append(("approvals", .approvals, .stream))
        for (name, destination, tab) in shots {
            model.navigation.select(steward: steward.id)
            model.navigation.destination = destination
            model.navigation.tab = tab
            let image = try #require(render(model, dark: scheme == "dark"))
            if let dir = ProcessInfo.processInfo.environment["ARYA_SCREENSHOTS_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme).png")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try image.write(to: url)
            }
        }
    }

    /// The seeded demo home when `ARYA_SCREENSHOTS_HOME` is set, else the fake workspace.
    private func makeModel() async throws -> AppModel {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ARYA_SCREENSHOTS_HOME"] {
            let workspace = try await Workspace.open(
                home: URL(fileURLWithPath: path, isDirectory: true), environment: environment)
            return AppModel(
                source: workspace,
                featureStore: FeatureStore(workspace: FacadeFeatureWorkspace(source: workspace)))
        }
        let now = FakeWorkspaceSource.referenceDate
        return AppModel(
            source: FakeWorkspaceSource(now: now),
            featureStore: FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now))
    }

    /// PNG bytes of the whole root view at 1120 × 800 pt, drawn through AppKit so scroll
    /// views render too.
    private func render(_ model: AppModel, dark: Bool) -> Data? {
        let view = RootView(model: model)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 800)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
