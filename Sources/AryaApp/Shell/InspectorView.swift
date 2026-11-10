import Arya
import AryaDesign
import SwiftUI

/// What the right-hand inspector shows, from the selection (STYLE.md Layout): a ledger event's
/// payload and hash, a run's facts and cost, else the steward's context, with Settings last.
enum InspectorFocus: Equatable {
    case event(String)
    case run(String)
    case steward(String)
    case none

    static func of(_ navigation: NavigationState) -> InspectorFocus {
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
        if let ended = run.endedAt {
            out.append(("Duration", duration(ended.timeIntervalSince(run.startedAt))))
        }
        out.append(("Cost", cost(run.costMicros)))
        let mine = events.filter { $0.run == run.id }
        let decisions = mine.filter { $0.type == "run.decision" }.count
        let tools = mine.filter { $0.type.hasPrefix("tool.") || $0.type.hasPrefix("action.") }
            .count
        out.append(("Steps", "\(mine.count) events · \(decisions) decisions · \(tools) tool"))
        out.append(("Proposed", "\(run.actionsProposed) actions"))
        out.append(("Charter", "v\(run.charterVersion)"))
        if let reason = run.failureReason { out.append(("Failure", reason)) }
        return out
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
/// (event, run, steward) and ends with Settings. Toggled with Option-Command-I or the gear.
struct InspectorView: View {
    let model: AppModel
    var now: Date = Date()
    @AppStorage(AryaApp.appearanceKey) private var appearance = AryaAppearance.dark.rawValue

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
                AryaHairline()
                settings
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
        case .event: "Event"
        case .run: "Run"
        case .steward: "Steward"
        case .none: "Settings"
        }
    }

    private var events: [FeatureEvent] {
        guard case .loaded(let events) = model.featureStore?.state else { return [] }
        return events
    }

    @ViewBuilder private var focusContent: some View {
        switch focus {
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
        if !context.plan.isEmpty {
            section("Plan") {
                ForEach(context.plan) { step in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Text(step.status.mark).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                            .accessibilityLabel(step.status.word)
                        Text(step.title).aryaText(AryaFont.caption, AryaColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    private var settings: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            section("Home") {
                Text(model.source.label).aryaText(AryaFont.mono, AryaColor.inkMuted)
            }
            section("Appearance") {
                ChoiceRow(
                    AryaAppearance.allCases.map { ($0, $0.rawValue.capitalized) },
                    selection: AryaAppearance(stored: appearance)
                ) { choice in
                    appearance = choice.rawValue
                    AryaApp.apply(choice)
                }
            }
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
