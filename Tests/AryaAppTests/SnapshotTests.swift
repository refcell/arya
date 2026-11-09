import AppKit
import Arya
import AryaDesign
import Foundation
import SwiftUI
import Testing

@testable import AryaApp

/// Visual checks without a window (decision 0038). `just snapshot` seeds or reuses the demo
/// home, sets `ARYA_SNAPSHOT_HOME` to it and `ARYA_SNAPSHOT_DIR` to `.build/snapshots`, and
/// this suite renders every key state offscreen through `NSHostingView.cacheDisplay`: no window,
/// no Dock icon, no focus change. Without the variables it renders the fake workspace and
/// writes nothing, so the rendering itself stays under test.
@MainActor @Suite struct SnapshotTests {
    /// The snapshot size in points.
    static let size = NSSize(width: 1400, height: 1000)

    @Test(arguments: ["dark", "light"])
    func snapshots(scheme: String) async throws {
        let dark = scheme == "dark"
        let model = try await makeModel()
        await model.refresh()
        await model.featureStore?.reload()
        let steward = try #require(model.stewards.first { $0.id == "st_triage" })
        let runs = model.runs[steward.id] ?? []
        let waiting = runs.first { run in model.approvals.contains { $0.run == run.id } }
        let quiet = runs.first { run in !model.approvals.contains { $0.run == run.id } }

        func page(_ name: String, _ arrange: (inout NavigationState) -> Void) throws {
            var navigation = NavigationState()
            navigation.select(steward: steward.id)
            arrange(&navigation)
            model.navigation = navigation
            try write(name, scheme: scheme, render(RootView(model: model), dark: dark))
        }
        try page("overview") { $0.tab = .overview }
        model.navigation = NavigationState()
        model.navigation.select(steward: steward.id)
        try write("window", scheme: scheme, renderInWindow(RootView(model: model), dark: dark))
        if let quiet { try page("run") { $0.select(run: quiet.id, steward: steward.id) } }
        if let waiting {
            try page("run-approval") { $0.select(run: waiting.id, steward: steward.id) }
        }
        try page("needs-you") { $0.showApprovals() }
        try page("improve") { $0.tab = .improve }
        try page("knowledge") { $0.tab = .knowledge }
        // The event inspector for a selected ledger row joins this set when app-views ships it.
        try page("ledger") { $0.tab = .ledger }
        try page("settings") { $0.inspector = true }
        // Sheets do not draw offscreen, so the New steward flow renders as its own page.
        model.navigation = NavigationState()
        model.navigation.select(steward: steward.id)
        let sheet = FeatureRegistry.newSteward(model.featureContext())
            .frame(width: 560, height: 640)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(AryaColor.canvas)
        try write("new-steward", scheme: scheme, render(sheet, dark: dark))
        // Steps 2-5 of the flow, filled with the example (app-outcome).
        if let store = model.featureContext().store {
            for step in NewStewardDraft.Step.allCases.dropFirst() {
                let page = NewStewardSheet(
                    store: store, draft: .example, step: step, created: { _ in }, cancel: {}
                )
                .frame(width: 560, height: 640)
                .frame(width: Self.size.width, height: Self.size.height)
                .background(AryaColor.canvas)
                try write(
                    "new-steward-\(step.rawValue + 1)", scheme: scheme, render(page, dark: dark))
            }
        }

        let empty = try await emptyModel()
        defer { try? FileManager.default.removeItem(at: empty.home) }
        await empty.model.refresh()
        try write("first-launch", scheme: scheme, render(RootView(model: empty.model), dark: dark))
    }

    /// The seeded demo home when `ARYA_SNAPSHOT_HOME` is set, else the fake workspace.
    private func makeModel() async throws -> AppModel {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ARYA_SNAPSHOT_HOME"] {
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

    /// A fresh, empty home in the temp directory, for the first-launch state.
    private func emptyModel() async throws -> (model: AppModel, home: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-snapshot-\(UUID().uuidString)", isDirectory: true)
        let workspace = try await Workspace.open(home: home)
        let model = AppModel(
            source: workspace,
            featureStore: FeatureStore(workspace: FacadeFeatureWorkspace(source: workspace)))
        return (model, home)
    }

    /// Writes `<name>.png` (dark) or `<name>-light.png` when `ARYA_SNAPSHOT_DIR` is set.
    private func write(_ name: String, scheme: String, _ png: Data?) throws {
        let png = try #require(png)
        guard let dir = ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_DIR"] else { return }
        let file = scheme == "dark" ? "\(name).png" : "\(name)-light.png"
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    /// PNG bytes of the view inside a real window frame with the app's chrome (transparent
    /// title bar, full-size content, traffic lights), so the title-bar rule can be judged. The
    /// window is never ordered on screen and the process may not activate, so nothing appears.
    private func renderInWindow(_ view: some View, dark: Bool) -> Data? {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = AryaColorToken.canvas.nsColor
        window.contentView = NSHostingView(
            rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        guard let frame = window.contentView?.superview else { return nil }
        frame.layoutSubtreeIfNeeded()
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            return nil
        }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// PNG bytes of a view at `size`, drawn through AppKit so scroll views render too.
    private func render(_ view: some View, dark: Bool) -> Data? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
