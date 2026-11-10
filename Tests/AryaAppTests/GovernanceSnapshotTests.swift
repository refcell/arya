import AppKit
import Arya
import AryaDesign
import Foundation
import SwiftUI
import Testing

@testable import Arya
@testable import AryaApp
@testable import AryaLedger

/// Governance states for `just snapshot` (decision 0038: offscreen, no window): the steward
/// inspector with tools, actions, approvers, and retention; the run header's Abort and Undo
/// with the abort question and the undo list; and app settings with retention and encryption.
/// On the demo home the data comes from the facade; without it, from fixtures, and nothing is
/// written.
@MainActor @Suite struct GovernanceSnapshotTests {
    @Test(arguments: ["dark", "light"])
    func governanceSnapshots(scheme: String) async throws {
        let dark = scheme == "dark"
        let cache = GovernanceCache.shared
        let environment = ProcessInfo.processInfo.environment
        var options = Self.fixtureOptions
        if let path = environment["ARYA_SNAPSHOT_HOME"] {
            let workspace = try await Workspace.open(
                home: URL(fileURLWithPath: path, isDirectory: true), environment: environment)
            let model = AppModel(
                source: workspace,
                featureStore: FeatureStore(workspace: FacadeFeatureWorkspace(source: workspace)))
            await model.refresh()
            await model.featureStore?.reload()
            let steward = try #require(model.stewards.first { $0.id == "st_triage" })
            await cache.load(steward: steward.id, from: workspace)
            await cache.loadHome(from: workspace)
            cache.exports[steward.id] = Self.fixtureExport
            var undoable: String?
            for run in model.runs[steward.id] ?? [] {
                await cache.load(run: run.id, from: workspace)
                if let found = cache.undo[run.id], !found.isEmpty {
                    options = found
                    undoable = run.id
                    break
                }
            }
            if let undoable {
                // The run's header carries Undo for its executed label.
                model.navigation = NavigationState()
                model.navigation.select(run: undoable, steward: steward.id)
                try write(
                    "governance-run", scheme: scheme,
                    render(
                        RootView(model: model), dark: dark,
                        size: NSSize(width: 1400, height: 1000)))
            }
            model.navigation = NavigationState()
            model.navigation.select(steward: steward.id)
            model.navigation.inspector = true
            try write(
                "governance-inspector", scheme: scheme,
                render(RootView(model: model), dark: dark, size: NSSize(width: 1400, height: 1000)))
            try write(
                "governance-settings", scheme: scheme,
                render(
                    AppSettingsView(home: model.source.label, governance: workspace), dark: dark,
                    size: AppSettingsView.windowSize))
        }
        let panel = PolicyPanel(
            policy: cache.policies["st_triage"] ?? Self.fixturePolicy, retentionDays: 90,
            homeDays: 365, setRetention: { _ in }
        )
        .padding(AryaSpace.s4)
        .frame(width: AryaSize.inspectorWidth, height: 520, alignment: .topLeading)
        try write(
            "governance-policy", scheme: scheme,
            render(
                panel.background(AryaColor.canvas), dark: dark,
                size: NSSize(width: 340, height: 520)))
        try write(
            "governance-run-controls", scheme: scheme,
            render(Self.runControls(options), dark: dark, size: NSSize(width: 820, height: 300)))
    }

    /// The header bar on a live run, and the two popovers it opens, side by side.
    static func runControls(_ options: [UndoOption]) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            HStack {
                Text("Labeled MSG-9 as billing · manual · started 2 s ago").aryaText(
                    AryaFont.monoSmall, AryaColor.inkFaint)
                Spacer()
                RunGovernanceBar(
                    running: true, options: options, problem: nil,
                    confirmAbort: .constant(false), showUndo: .constant(false),
                    reason: .constant(""), abort: { _ in }, undo: { _ in })
            }
            HStack(alignment: .top, spacing: AryaSpace.s4) {
                AbortConfirm(reason: .constant("Wrong customer"), confirm: {}, cancel: {})
                    .padding(AryaSpace.s3)
                    .background(AryaColor.raised)
                    .clipShape(RoundedRectangle(cornerRadius: AryaRadius.small))
                UndoList(options: options, undo: { _ in })
                    .padding(AryaSpace.s3)
                    .background(AryaColor.raised)
                    .clipShape(RoundedRectangle(cornerRadius: AryaRadius.small))
            }
        }
        .padding(AryaSpace.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AryaColor.canvas)
    }

    static let fixtureExport: AuditExportSummary = {
        let manifest = AuditManifest(
            v: 1, steward: "st_triage", count: 64, first: 3, last: 2231, head: 2235,
            headHash: String(repeating: "0", count: 64), events: "", keys: "", payloads: nil,
            sealed: 0, key: "key_3f9a0c1d2e4b5a6c", publicKey: "", signature: nil)
        return AuditExportSummary(
            directory: URL(fileURLWithPath: "/exports/st_triage-audit-20261110T090000Z"),
            manifest: manifest, revealed: false, issues: [])
    }()

    static let fixtureOptions = [
        UndoOption(
            run: "run_1", action: "a1", kind: "label", binding: "inbox", target: "inbox:MSG-9",
            with: "unlabel", note: "Labels can be taken back", undoneBy: nil),
        UndoOption(
            run: "run_1", action: "a2", kind: "route", binding: "inbox", target: "inbox:MSG-9",
            with: "unroute", note: nil, undoneBy: "local"),
    ]

    static let fixturePolicy = PolicySummary(
        steward: "st_triage", autonomy: "act_low", fallback: "ask",
        bindings: [
            .init(
                id: "inbox", kind: "mcp", tools: ["list_messages", "read_message"],
                network: false, via: nil,
                actions: [
                    .init(
                        kind: "label", decision: "auto", reason: "rule:label", risk: "low",
                        approvers: nil, approverNote: nil),
                    .init(
                        kind: "refund", decision: "ask", reason: "rule:refund", risk: "high",
                        approvers: ["person:alex"], approverNote: "Refunds need the billing lead"),
                ])
        ],
        approvers: [
            .init(
                action: "refund", binding: nil, people: ["person:alex"],
                note: "Refunds need the billing lead")
        ])

    private func write(_ name: String, scheme: String, _ png: Data?) throws {
        let png = try #require(png)
        guard let dir = ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_DIR"] else { return }
        let file = scheme == "dark" ? "\(name).png" : "\(name)-light.png"
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    private func render(_ view: some View, dark: Bool, size: CGSize) -> Data? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
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
