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
    /// A connection selected on the Connections page.
    case connection(String)
    /// A person selected on the People page.
    case person(String)
    case run(String)
    case steward(String)
    /// The All stewards table: the fleet pulse.
    case fleet
    case none

    var isRun: Bool {
        if case .run = self { return true }
        return false
    }

    static func of(_ navigation: NavigationState) -> InspectorFocus {
        if navigation.destination == .approvals { return .approval(navigation.approval) }
        if navigation.destination == .portfolio { return .fleet }
        if case .connections = navigation.destination {
            if let connection = navigation.connection { return .connection(connection) }
        }
        // People always shows a person: "" stands for the directory's first person, so the
        // inspector is never empty on that page.
        if case .people = navigation.destination, navigation.peoplePane == .people {
            return .person(navigation.person ?? "")
        }
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

    static func build(
        events: [FeatureEvent], steward: String, now: Date, serve: FeatureServe? = nil
    ) -> StewardContext {
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
                ? OutcomeState.build(
                    events: events, steward: steward, now: now, serve: serve)
                : nil,
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
        // The run header's own figures (app-views' RunMetrics), "—" when unknown.
        let facts = RunStream.build(events: events, run: run.id).facts
        out.append(("Duration", facts.seconds.map(FeatureTime.duration) ?? "—"))
        let micros = facts.costMicros ?? 0
        out.append(("Cost", micros > 0 ? RunMetrics.dollars(micros) : "—"))
        if let tokens = facts.tokens, tokens > 0 {
            out.append(("Tokens", RunMetrics.grouped(tokens)))
        }
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
                    AryaIconButton("sidebar.right", label: "Hide the inspector", keys: "⌥⌘I") {
                        withAnimation(AryaMotion.panel) { model.navigation.inspector = false }
                    }
                }
                focusContent
            }
            .padding(.horizontal, AryaSpace.s4)
            .padding(.top, AryaSize.titleBarInset)
            .padding(.bottom, AryaSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Narrower beside a run, so the work pane keeps its room.
        .frame(width: focus.isRun ? AryaSize.inspectorNarrowWidth : AryaSize.inspectorWidth)
        .accessibilityLabel("Inspector")
    }

    private var focus: InspectorFocus { InspectorFocus.of(model.navigation) }

    private var heading: String {
        switch focus {
        case .approval: "Steward"
        case .event: "Event"
        case .connection: "Connection"
        case .person: "Person"
        case .run: "Run"
        case .steward: "Steward"
        case .fleet: "All stewards"
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
            // The approval itself fills the stream's detail pane; here, its steward's pulse.
            if let id = id ?? model.approvals.first?.id,
                let approval = model.approvals.first(where: { $0.id == id }),
                let steward = model.stewards.first(where: { $0.id == approval.steward })
            {
                Text(steward.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                StewardPulseView(
                    pulse: StewardPulse.build(
                        steward: steward, runs: model.runs[steward.id] ?? [],
                        approvals: model.approvals, events: events, now: now)
                ) { model.navigation.approval = $0 }
            } else if let id = id ?? model.approvals.first?.id {
                FeatureRegistry.approvalInspector(model.featureContext(), approval: id)
            } else {
                Text("Nothing needs you.").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        case .event(let id):
            FeatureRegistry.eventInspector(model.featureContext(), event: id)
        case .connection(let id):
            FeatureRegistry.connectionInspector(model.featureContext(), connection: id)
        case .person(let id):
            FeatureRegistry.personInspector(model.featureContext(), person: id)
        case .run:
            if let run = model.selectedRun { runContent(run) }
        case .steward:
            if let steward = model.selectedSteward { stewardContent(steward) }
        case .fleet:
            FleetPulseView(
                pulse: FleetPulse.build(
                    stewards: model.stewards, runs: model.runs, approvals: model.approvals,
                    events: events, now: now)
            ) { model.navigation.select(steward: $0) }
        case .none:
            Text("Select a steward to see its schedule, policy, connections, and people.")
                .aryaText(AryaFont.caption, AryaColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
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
        let context = StewardContext.build(
            events: events, steward: steward.id, now: now, serve: model.featureStore?.serve)
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                Text(steward.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                if steward.status != .active {
                    Text(steward.status.rawValue).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
            }
            HStack(spacing: AryaSpace.s2) {
                Button("Edit charter…") { FeatureRegistry.editCharter(model) }
                    .buttonStyle(.aryaSecondary)
                if steward.status == .paused {
                    Button("Resume") { Task { await model.setPaused(false) } }
                        .buttonStyle(.aryaSecondary(keys: "⌥⌘P"))
                } else {
                    Button("Pause") { Task { await model.setPaused(true) } }
                        .buttonStyle(.aryaSecondary(keys: "⌥⌘P"))
                        .disabled(steward.status != .active)
                }
            }
            .padding(.top, AryaSpace.s1)
        }
        StewardPulseView(
            pulse: StewardPulse.build(
                steward: steward, runs: model.runs[steward.id] ?? [], approvals: model.approvals,
                events: events, now: now)
        ) { id in
            model.navigation.showApprovals()
            model.navigation.approval = id
        }
        if let state = context.state {
            OutcomeSchedule(state: state, now: now)
            section("Policy") {
                Text(state.autonomy.text).aryaText(AryaFont.monoSmall, AryaColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        StewardGovernanceSection(model: model, steward: steward.id)
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
