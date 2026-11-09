import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AryaDesign

@Suite struct VocabularyTests {
    @Test func onlyTheLiveStatusIsAccented() {
        let accented = AryaStatus.allCases.filter { $0.dotToken == .accent }
        #expect(accented == [.running])
        #expect(AryaStatus.allCases.filter(\.isLive) == [.running])
        #expect(AryaStatus.allCases.allSatisfy { !$0.word.isEmpty })
    }

    @Test func policyChipColorsFollowTheGuide() {
        #expect(AryaPolicy.auto.textToken == .positive)
        #expect(AryaPolicy.ask.textToken == .accent)
        #expect(AryaPolicy.ask.borderToken == .accent)
        #expect(AryaPolicy.deny.textToken == .negative)
        #expect(AryaPolicy.deny.borderToken == .rule)
    }

    @Test func effortLevelsAndTooltip() {
        #expect(AryaEffort.allCases.map(\.label) == ["low", "medium", "high"])
        #expect(AryaEffort.tooltip == "More effort: slower, more thorough runs")
    }

    @Test func relativeTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AryaTime.relative(now.addingTimeInterval(-5), now: now) == "just now")
        #expect(AryaTime.relative(now.addingTimeInterval(-120), now: now) == "2m ago")
        #expect(AryaTime.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3h ago")
        #expect(AryaTime.relative(now.addingTimeInterval(-5 * 86_400), now: now) == "5d ago")
    }

    @Test func absoluteTimeMatchesTheGuide() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 2)))
        #expect(AryaTime.absolute(date, timeZone: utc) == "9 Nov 2026, 14:02")
    }

    @Test func sequenceNumbersPadToTwoDigits() {
        #expect(AryaTime.sequence(1) == "01")
        #expect(AryaTime.sequence(14) == "14")
        #expect(AryaTime.sequence(120) == "120")
    }

    @Test func countsHideAtZero() {
        #expect(CountLabel.text(for: 0) == nil)
        #expect(CountLabel.text(for: 2) == "2")
    }

    @Test func approvalCardKeys() {
        #expect(ApprovalCard.action(for: .return, modifiers: .command) == .approve)
        #expect(ApprovalCard.action(for: .delete, modifiers: .command) == .deny)
        // A plain Return or Delete on a card that took focus does nothing (decision 0034).
        #expect(ApprovalCard.action(for: .return, modifiers: []) == nil)
        #expect(ApprovalCard.action(for: .delete, modifiers: []) == nil)
        #expect(ApprovalCard.action(for: .escape, modifiers: .command) == nil)
    }

    @Test func threadTimesAreShort() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ThreadRow.shortTime(now, now: now) == "now")
        #expect(ThreadRow.shortTime(now.addingTimeInterval(-240), now: now) == "4m")
        #expect(ThreadRow.shortTime(now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(ThreadRow.shortTime(now.addingTimeInterval(-259_200), now: now) == "3d")
    }

    @Test func sparklinePointsFillTheRect() {
        let size = CGSize(width: 80, height: 20)
        let points = Sparkline.points([1, 3, 2], in: size)
        #expect(points.map(\.x) == [0, 40, 80])
        #expect(points.map(\.y) == [20, 0, 10])
        #expect(Sparkline.points([5, 5], in: size).allSatisfy { $0.y == 10 })
        #expect(Sparkline.points([], in: size).isEmpty)
    }

    @Test func diffLinesAreClassified() {
        let lines = DiffLine.parse("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same")
        #expect(lines.map(\.kind) == [.header, .header, .hunk, .removed, .added, .context])
        #expect(lines[3].markToken == .negative && lines[4].markToken == .positive)
        #expect(lines.allSatisfy { $0.textToken == .ink || $0.textToken == .inkMuted })
    }
}

@MainActor @Suite struct ComponentRenderTests {
    /// Renders a view offscreen in an appearance and returns its pixel size.
    func render(_ view: some View, dark: Bool) -> CGSize? {
        let renderer = ImageRenderer(
            content: view.frame(width: 640).environment(\.colorScheme, dark ? .dark : .light))
        return renderer.nsImage?.size
    }

    @Test(arguments: [false, true])
    func everyComponentRenders(dark: Bool) {
        var effort = AryaEffort.medium
        var tab = 1
        let effortBinding = Binding(get: { effort }, set: { effort = $0 })
        let tabBinding = Binding(get: { tab }, set: { tab = $0 })
        let views: [AnyView] = [
            AnyView(Button("Approve and run") {}.buttonStyle(.aryaPrimary)),
            AnyView(Button("Deny") {}.buttonStyle(.aryaSecondary)),
            AnyView(Button("Show more") {}.buttonStyle(.aryaTertiary).disabled(true)),
            AnyView(StatusBadge(.running)),
            AnyView(PolicyChip(.ask)),
            AnyView(Chip("st_triage")),
            AnyView(RailRow("Triage keeper", status: .running, isSelected: true)),
            AnyView(RailRow("run 14", trailing: "2m ago", indent: AryaSpace.s4)),
            AnyView(RailGroupLabel("Stewards")),
            AnyView(StepRow(sequence: 1, time: "2m ago", isRunning: true) { Text("Read") }),
            AnyView(TableRowFrame(isSelected: true) { Text("evt_1") }),
            AnyView(
                ApprovalCard(
                    action: "close_issue #418", summary: "Close a duplicate issue",
                    rationale: "It repeats #411.", context: "Triage keeper · run 14",
                    onDeny: {}, onApprove: {})),
            AnyView(EmptyState("No runs yet.", guidance: "A run starts when a routine fires.")),
            AnyView(CodeBlock("arya run st_triage")),
            AnyView(DiffBlock("@@ -1 +1 @@\n-old\n+new")),
            AnyView(EffortSelector(selection: effortBinding)),
            AnyView(
                TextTabBar(
                    tabs: [
                        TextTab(id: 0, title: "Stream"), TextTab(id: 1, title: "Changes", count: 3),
                    ],
                    selection: tabBinding)),
            AnyView(AryaHairline()),
        ]
        for view in views {
            let size = render(view, dark: dark)
            #expect(size != nil && (size?.width ?? 0) > 0)
        }
    }
}
