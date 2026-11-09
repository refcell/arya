import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AryaApp

/// Renders the preview shell offscreen. `just screenshots` sets `ARYA_SCREENSHOTS_DIR` to write
/// PNGs for the README and visual review; otherwise the renders only have to succeed.
@MainActor @Suite struct ScreenshotTests {
    @Test(arguments: ["light", "dark"])
    func shellScreenshots(scheme: String) async throws {
        let now = ShellPreviewWorkspace.referenceDate
        let store = FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now)
        let model = AppModel(source: ShellPreviewWorkspace(now: now), featureStore: store)
        await model.refresh()
        await store.reload()
        model.navigation.select(run: "run_0002", steward: "st_triage")
        let shots: [(String, Destination)] = [
            ("steward", .steward("st_triage")), ("approvals", .approvals),
        ]
        for (name, destination) in shots {
            model.navigation.destination = destination
            let image = try #require(render(model, dark: scheme == "dark"))
            if let dir = ProcessInfo.processInfo.environment["ARYA_SCREENSHOTS_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme).png")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try image.write(to: url)
            }
        }
    }

    /// PNG bytes of the whole root view at 1120 × 720 pt, drawn through AppKit so scroll
    /// views render too.
    private func render(_ model: AppModel, dark: Bool) -> Data? {
        let view = RootView(model: model, now: { ShellPreviewWorkspace.referenceDate })
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
