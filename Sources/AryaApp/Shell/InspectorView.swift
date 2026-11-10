import Arya
import AryaDesign
import SwiftUI

/// What the right-hand inspector shows, from the selection (STYLE.md Layout): a ledger event's
/// payload and hash, an approval's context, a run's facts and cost, else the steward's
/// context. App settings (home, appearance) live in the Settings window, not here.
enum InspectorFocus: Equatable {
    /// An approval in Needs you: nil until the queue has one.
    case approval(String?)
    case event(String)
    case run(String)
    case steward(String)
    case none

    static func of(_ navigation: NavigationState) -> InspectorFocus {
        if navigation.destination == .approvals { return .approval(navigation.approval) }
        if navigation.tab == .ledger, navigation.steward != nil,
            let event = navigation.ledgerEvent
        {
            return .event(event)
        }
        if let run = navigation.run { return .run(run) }
        if let steward = navigation.steward { return .steward(steward) }
        return .none
    }
}

/// The steward context the inspector lists when nothing is selected, read from the ledger.
struct StewardContext: Equatable {
    var plan: [OutcomePlan.Step]
    var state: OutcomeState?
    /// "inbox · mcp · read, actions", one per charter binding.
    var connections: [String]
    /// People who acted on this steward (approved, corrected, edited), most active first.
    var people: [String]

    static func build(events: [FeatureEvent], steward: String, now: Date) -> StewardContext {
        let charter = LiveCharter.find(events: events, steward: steward)?.charter
        let connections = (charter?["bindings"]?.array ?? []).compactMap { binding -> String? in
            guard let id = binding["id"]?.string else { return nil }
            let scopes = ["read", "actions"].filter { !(binding[$0]?.strings.isEmpty ?? true) }
            return ([id, binding["kind"]?.string ?? ""] + [scopes.joined(separator: ", ")])
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var counts: [String: Int] = [:]
        for event in events where event.steward == steward && event.actor.kind == .human {
            counts[event.actor.id, default: 0] += 1
        }
        let people = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) · \($0.value) \($0.value == 1 ? "action" : "actions")" }
        let hasCharter = charter != nil
        return StewardContext(
            plan: OutcomePlan.build(events: events, steward: steward)?.steps ?? [],
            state: hasCharter
                ? OutcomeState.build(events: events, steward: steward, now: now) : nil,
            connections: connections, people: people)
    }
}

/// A run's facts for the inspector: status, trigger, timing, cost, and step counts.
enum RunFacts {
    static func lines(_ run: RunSummary, events: [FeatureEvent], now: Date) -> [(String, String)] {
        var out: [(String, String)] = [
            ("Status", run.status.rawValue),
            ("Trigger", run.trigger.isEmpty ? "manual" : run.trigger),
            ("Started", AryaTime.label(run.startedAt, now: now)),
        ]
        // Unknown reads "—": a run that did work never shows 0.0 s or $0.
        let seconds = run.endedAt.map { $0.timeIntervalSince(run.startedAt) } ?? 0
        out.append(("Duration", seconds > 0 ? duration(seconds) : "—"))
        out.append(("Cost", run.costMicros > 0 ? cost(run.costMicros) : "—"))
        let mine = events.filter { $0.run == run.id }
        let decisions = mine.filter { $0.type == "run.decision" }.count
        let tools = mine.filter { $0.type.hasPrefix("tool.") || $0.type.hasPrefix("action.") }
            .count
        out.append(
            (
                "Steps",
                [count(mine.count, "event"), count(decisions, "decision"), count(tools, "tool")]
                    .joined(separator: " · ")
            ))
        out.append(("Proposed", count(run.actionsProposed, "action")))
        out.append(("Charter", "v\(run.charterVersion)"))
        if let reason = run.failureReason { out.append(("Failure", reason)) }
        return out
    }

    /// "1 decision", "4 tools".
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// "0.2 s", "42 s", "3m 05s", "1h 12m".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", max(0, seconds)) }
        let whole = Int(seconds)
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }

    /// "$0.042" from micro-dollars; "$0" when free.
    static func cost(_ micros: Int) -> String {
        if micros == 0 { return "$0" }
        let dollars = Double(micros) / 1_000_000
        return dollars < 1 ? String(format: "$%.3f", dollars) : String(format: "$%.2f", dollars)
    }
}

/// The right-hand inspector on the same canvas, behind a hairline: it follows the selection
/// (approval, event, run, steward). Toggled with Option-Command-I.
struct InspectorView: View {
    let model: AppModel
    var now: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                HStack {
                    Text(heading).aryaText(AryaFont.label, AryaColor.inkFaint)
                    Spacer()
                    Button("Hide") { model.navigation.inspector = false }
                        .buttonStyle(.aryaTertiary)
                        .help("Hide the inspector (Option-Command-I)")
                }
                focusContent
            }
            .padding(.horizontal, AryaSpace.s4)
            .padding(.top, AryaSize.titleBarInset)
            .padding(.bottom, AryaSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: AryaSize.inspectorWidth)
        .accessibilityLabel("Inspector")
    }

    private var focus: InspectorFocus { InspectorFocus.of(model.navigation) }

    private var heading: String {
        switch focus {
        case .approval: "Approval"
        case .event: "Event"
        case .run: "Run"
        case .steward: "Steward"
        case .none: "Inspector"
        }
    }

    private var events: [FeatureEvent] {
        guard case .loaded(let events) = model.featureStore?.state else { return [] }
        return events
    }

    @ViewBuilder private var focusContent: some View {
        switch focus {
        case .approval(let id):
            if let approval = model.approvals.first(where: { $0.id == id })
                ?? model.approvals.first
            {
                approvalContent(approval)
            } else {
                Text("Nothing needs you.").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        case .event(let id):
            FeatureRegistry.eventInspector(model.featureContext(), event: id)
        case .run:
            if let run = model.selectedRun { runContent(run) }
        case .steward:
            if let steward = model.selectedSteward { stewardContent(steward) }
        case .none:
            EmptyView()
        }
    }

    /// The oldest (or selected) approval's essentials until Needs you shares its selection
    /// and app-views' fuller approval inspector is mounted here.
    private func approvalContent(_ approval: ApprovalSummary) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text([approval.actionKind, approval.target].compactMap { $0 }.joined(separator: " "))
                .aryaText(AryaFont.monoStrong, AryaColor.ink)
            fact("Steward", model.stewards.first { $0.id == approval.steward }?.name ?? "")
            if let run = model.runs[approval.steward]?.first(where: { $0.id == approval.run }) {
                fact("Run", StatusMapping.threadTitle(of: run))
            }
            fact("Asked", AryaTime.label(approval.requestedAt, now: now))
            if let policy = approval.policyText ?? approval.policyRule { fact("Policy", policy) }
            if let risk = approval.risk { fact("Risk", risk) }
        }
    }

    private func runContent(_ run: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text(StatusMapping.threadTitle(of: run)).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(RunFacts.lines(run, events: events, now: now), id: \.0) { label, value in
                fact(label, value)
            }
        }
    }

    @ViewBuilder private func stewardContent(_ steward: StewardSummary) -> some View {
        let context = StewardContext.build(events: events, steward: steward.id, now: now)
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                Text(steward.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                if steward.status != .active {
                    Text(steward.status.rawValue).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
            }
            HStack(spacing: AryaSpace.s3) {
                Button("Edit charter…") { FeatureRegistry.editCharter(model) }
                    .buttonStyle(.aryaTertiary)
                if steward.status == .paused {
                    Button("Resume") { Task { await model.setPaused(false) } }
                        .buttonStyle(.aryaTertiary)
                } else {
                    Button("Pause") { Task { await model.setPaused(true) } }
                        .buttonStyle(.aryaTertiary)
                        .disabled(steward.status != .active)
                }
            }
        }
        if let state = context.state {
            OutcomeSchedule(state: state, now: now)
            section("Policy") {
                Text(state.autonomy.text).aryaText(AryaFont.monoSmall, AryaColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        section("Connections") {
            if context.connections.isEmpty {
                Text("None").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(context.connections, id: \.self) {
                Text($0).aryaText(AryaFont.monoSmall, AryaColor.ink)
            }
            Button("Connections…") { model.navigation.showConnections() }
                .buttonStyle(.aryaQuiet)
                .help("Connect systems, test them, and keep their secrets (Shift-Command-K)")
        }
        section("People") {
            if context.people.isEmpty {
                Text("No one has acted yet").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(context.people, id: \.self) {
                Text($0).aryaText(AryaFont.monoSmall, AryaColor.ink)
            }
            Button("People…") { model.navigation.showPeople() }
                .buttonStyle(.aryaQuiet)
                .help("Who it works with and what they may approve (Shift-Command-P)")
        }
        section("Effort") {
            let effort = effortBinding(steward.id)
            ChoiceRow(
                AryaEffort.allCases.map { ($0, $0.label.capitalized) },
                selection: effort.wrappedValue
            ) { effort.wrappedValue = $0 }
            .help(AryaEffort.tooltip)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(label).aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(width: 72, alignment: .leading)
            Text(value).aryaText(AryaFont.monoSmall, AryaColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title).aryaText(AryaFont.label, AryaColor.inkFaint)
            content()
        }
    }

    private func effortBinding(_ steward: String) -> Binding<AryaEffort> {
        Binding(
            get: { model.effort(for: steward) },
            set: { effort in Task { await model.setEffort(effort, steward: steward) } })
    }
}
