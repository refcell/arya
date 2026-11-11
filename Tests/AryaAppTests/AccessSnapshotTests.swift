import AppKit
import Arya
import AryaDesign
import Foundation
import SwiftUI
import Testing

@testable import Arya
@testable import AryaApp

/// Settings ▸ Access for `just snapshot access access-refusals access-window` (decision 0038:
/// offscreen, no window). On the demo home the overview comes from the facade, with a team and
/// two grants added to a scratch copy when it has none; without the home, from fixtures.
/// `access-window` shows the page in the whole window: sidebar, Access, and its inspector.
@MainActor @Suite struct AccessSnapshotTests {
    @Test(arguments: ["dark", "light"])
    func accessSnapshots(scheme: String) async throws {
        guard
            SnapshotTests.wants("access") || SnapshotTests.wants("access-refusals")
                || SnapshotTests.wants("access-window")
        else { return }
        SnapshotProgress.begin("access snapshots (\(scheme))")
        defer { SnapshotProgress.end() }
        let model = AccessModel(overview: Self.fixture)
        var source: (any AccessSettingsSource)?
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ARYA_SNAPSHOT_HOME"] {
            let workspace = try await Workspace.open(
                home: URL(fileURLWithPath: path, isDirectory: true), environment: environment)
            await model.load(from: workspace)
            // Once per run: the dark and light cases share the scratch home.
            if model.overview?.grants.isEmpty == true, !Self.seeded {
                Self.seeded = true
                // The snapshot home is a scratch copy; give it a team and grants to show.
                let people = model.overview?.people ?? []
                if people.count >= 2 {
                    _ = await model.setTeam(
                        "team:support", name: "Support", members: Array(people.prefix(2)),
                        from: workspace)
                }
                let connection = model.overview?.resources.first { $0.kind == "connection" }
                if let connection {
                    _ = await model.grant(
                        GrantDraft(subject: "team:support", level: "use", resource: connection.id),
                        from: workspace)
                }
                if let person = people.first {
                    _ = await model.grant(
                        GrantDraft(subject: person, level: "approve", resource: "*"),
                        from: workspace)
                }
            }
            if model.overview?.refusals.isEmpty == true, let fixture = Self.fixture.refusals.first {
                // Refusals come from runs; the demo home has none yet, so show the fixture's.
                var overview = try #require(model.overview)
                overview.refusals = [fixture] + Self.fixture.refusals.dropFirst()
                let known = Set(overview.resources.map(\.id))
                overview.resources += Self.fixture.resources.filter { !known.contains($0.id) }
                model.replace(overview)
            }
            source = workspace
        }
        let dark = scheme == "dark"
        try write(
            "access", scheme: scheme,
            render(AccessSettingsView(source: source, model: model, tab: .grants), dark: dark))
        try write(
            "access-refusals", scheme: scheme,
            render(AccessSettingsView(source: source, model: model, tab: .refused), dark: dark))
        if SnapshotTests.wants("access-window") {
            try await window(model: model, source: source, scheme: scheme, dark: dark)
        }
    }

    /// The whole window on Settings ▸ Access: the sidebar, the page in the stream, and the
    /// Access inspector, at the main snapshot size.
    private func window(
        model access: AccessModel, source: (any AccessSettingsSource)?, scheme: String,
        dark: Bool
    ) async throws {
        let app: AppModel
        if let workspace = source as? Workspace {
            app = AppModel(
                source: workspace,
                featureStore: FeatureStore(workspace: FacadeFeatureWorkspace(source: workspace)))
        } else {
            let now = FakeWorkspaceSource.referenceDate
            app = AppModel(
                source: FakeWorkspaceSource(now: now),
                featureStore: FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now))
        }
        await app.refresh()
        await app.featureStore?.reload()
        app.navigation.showAccess()
        // The page reads the shared model; offscreen renders run no `.task`, so fill it first.
        if let overview = access.overview { AccessModel.shared.replace(overview) }
        try write(
            "access-window", scheme: scheme,
            render(RootView(model: app), dark: dark, size: SnapshotTests.size))
    }

    static let now = Date()
    nonisolated(unsafe) static var seeded = false

    static let fixture = AccessOverview(
        enforced: true,
        teams: [
            AccessTeamSummary(
                id: "team:support", name: "Support", members: ["person:sam", "person:ana"])
        ],
        grants: [
            AccessGrantSummary(
                subject: "team:support", level: "use", resource: "connection:inbox", by: "local",
                at: now.addingTimeInterval(-3600), seq: 40),
            AccessGrantSummary(
                subject: "person:ana", level: "approve", resource: "steward:st_triage",
                by: "local", at: now.addingTimeInterval(-1800), seq: 41),
            AccessGrantSummary(
                subject: "person:lena", level: "use", resource: "tool:billing.refund",
                by: "person:ana", at: now.addingTimeInterval(-600), seq: 42),
        ],
        refusals: [
            AccessRefusalSummary(
                seq: 90, at: now.addingTimeInterval(-300), steward: "st_refunds", run: "run_1",
                person: "person:sam", level: "use", action: "refund",
                reason: "person:sam has no use grant for refund on billing",
                resources: ["tool:billing.refund", "connection:billing", "steward:st_refunds"]),
            AccessRefusalSummary(
                seq: 88, at: now.addingTimeInterval(-2400), steward: "st_triage", run: "run_2",
                person: "person:sam", level: "approve", action: "reply",
                reason: "person:sam has no approve grant for reply on st_triage",
                resources: ["steward:st_triage"]),
        ],
        people: ["person:ana", "person:lena", "person:sam"],
        resources: [
            AccessResource(id: "*", kind: "everything", label: "Everything"),
            AccessResource(id: "steward:st_triage", kind: "steward", label: "Support inbox triage"),
            AccessResource(id: "steward:st_refunds", kind: "steward", label: "Refunds"),
            AccessResource(id: "connection:inbox", kind: "connection", label: "inbox"),
            AccessResource(id: "tool:billing.refund", kind: "tool", label: "billing.refund"),
        ],
        lastChange: AccessChangeSummary(
            seq: 42, text: "Granted use on tool:billing.refund to person:lena", by: "person:ana",
            at: now.addingTimeInterval(-600), undoable: true, kind: "granted",
            grant: AccessGrantSummary(
                subject: "person:lena", level: "use", resource: "tool:billing.refund",
                by: "person:ana", at: now.addingTimeInterval(-600), seq: 42)))

    private func write(_ name: String, scheme: String, _ png: @autoclosure () -> Data?) throws {
        let file = scheme == "dark" ? "\(name).png" : "\(name)-light.png"
        SnapshotProgress.passed(file)
        guard SnapshotTests.wanted(name, file: file) else { return }
        let png = try #require(png())
        guard let dir = ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        SnapshotSpace.report(name, file: file, png: png, dir: dir)
    }

    private func render(
        _ view: some View, dark: Bool, size: CGSize = AccessSettingsView.windowSize
    ) -> Data? {
        let still = view.environment(\.colorScheme, dark ? .dark : .light)
            .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: still)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
