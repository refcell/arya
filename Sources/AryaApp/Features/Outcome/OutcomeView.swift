import AryaDesign
import SwiftUI

/// Everything the Overview tab shows for one steward, built from the ledger's events.
struct OutcomeSnapshot: Hashable, Sendable {
    var state: OutcomeState
    var plan: OutcomePlan?
    var recap: OutcomeRecap
    var activity: [OutcomeActivity]

    static func build(
        events: [FeatureEvent], steward: String, now: Date, lastSeen: Int?,
        serve: FeatureServe? = nil
    ) -> OutcomeSnapshot {
        let activity = OutcomeActivityFeed.build(events: events, steward: steward)
        return OutcomeSnapshot(
            state: OutcomeState.build(events: events, steward: steward, now: now, serve: serve),
            plan: OutcomePlan.build(events: events, steward: steward),
            recap: OutcomeRecap.build(
                events: events, steward: steward, activity: activity, lastSeen: lastSeen),
            activity: activity)
    }
}

/// Remembers the newest ledger seq a person saw on each steward's Overview.
enum OutcomeVisits {
    static func key(_ steward: String) -> String { "arya.outcome.lastSeen.\(steward)" }

    static func lastSeen(_ steward: String, defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: key(steward)) as? Int
    }

    static func record(_ seq: Int, steward: String, defaults: UserDefaults = .standard) {
        defaults.set(seq, forKey: key(steward))
    }
}

/// The default steward tab. Reads top to bottom with no boxes: a recap when the person comes
/// back, the current plan, recent activity with why, and the charter's details on demand.
struct OverviewTab: View {
    @ObservedObject var store: FeatureStore
    let steward: String
    /// Opens a run's transcript.
    let openRun: (String) -> Void
    /// Opens the approvals waiting on the person.
    let openApprovals: () -> Void
    /// Opens rehearsals, the next step for a steward that is not ready.
    let rehearse: () -> Void
    /// Starts the scheduler from the app; nil where the shell cannot.
    var startServing: (() -> Void)?
    /// The seq the person had seen before this visit; read once per steward.
    @AryaState private var lastSeen: Int?
    @AryaState private var visited: String?

    var body: some View {
        Group {
            switch store.state {
            case .loading:
                EmptyState("Loading the overview.", guidance: "")
            case .failed(let message):
                EmptyState("Could not load the overview.", guidance: message)
            case .loaded(let events):
                if LiveCharter.find(events: events, steward: steward) == nil {
                    EmptyState(
                        "No charter yet.",
                        guidance: "A steward's overview appears once its charter is recorded.")
                } else {
                    content(events)
                }
            }
        }
        .task(id: steward) { visit() }
        .task(id: "\(steward)#\(revision)") { await loadReads() }
    }

    /// Changes as the ledger grows, so new findings and checks reload.
    private var revision: Int {
        if case .loaded(let events) = store.state { return events.count }
        return 0
    }

    /// The workspace's findings and effectiveness; a home without them keeps the projections.
    private func loadReads() async {
        let live = try? await store.workspace.stewardLive(steward: steward)
        let findings = try? await store.workspace.overviewFindings(steward: steward)
        let impact = try? await store.workspace.impact(steward: steward)
        let onboarding = try? await store.workspace.onboarding(steward: steward)
        let metrics = try? await store.workspace.metricStatuses(
            steward: steward, windows: OutcomeMetrics.seriesDays)
        let missed: String?? =
            if let read = try? await store.workspace.outcomeMissedText(steward: steward) {
                .some(read)
            } else {
                nil
            }
        let runs = try? await store.workspace.runHistory(steward: steward)
        store.outcomeReads[steward] = OutcomeReads(
            live: live, findings: findings, impact: impact ?? nil, onboarding: onboarding,
            metrics: metrics, missedText: missed, runs: runs)
        if let queue = try? await store.workspace.reviewQueue(steward: steward) {
            store.reviewQueues[steward] = queue
        }
        if onboarding != nil, let gate = try? await store.workspace.goLiveGate(steward: steward) {
            store.goLiveGates[steward] = gate
        }
    }

    private func visit() {
        guard visited != steward else { return }
        visited = steward
        lastSeen = OutcomeVisits.lastSeen(steward)
        if let newest = store.events.last?.seq { OutcomeVisits.record(newest, steward: steward) }
    }

    private func content(_ events: [FeatureEvent]) -> some View {
        var snapshot = OutcomeSnapshot.build(
            events: events, steward: steward, now: store.now, lastSeen: lastSeen,
            serve: store.serve)
        snapshot.state = snapshot.state.applying(store.outcomeReads[steward])
        let seenAt = lastSeen.flatMap { seq in events.last { $0.seq <= seq }?.at }
        return ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                if !snapshot.state.readiness.isReady {
                    if let onboarding = store.outcomeReads[steward]?.onboarding {
                        OnboardingPanel(
                            store: store, steward: steward,
                            steps: OnboardingSteps.build(
                                onboarding: onboarding, gate: store.goLiveGates[steward],
                                events: events, steward: steward))
                    } else if case .notReady(let reason) = snapshot.state.readiness {
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            Text("Not ready: \(reason).")
                                .aryaText(AryaFont.body, AryaColor.inkMuted)
                            Button("Rehearse on past work", action: rehearse)
                                .buttonStyle(.aryaTertiary)
                        }
                    }
                }
                if let recap = OutcomeRecapText.paragraph(
                    snapshot.recap, seenAt: seenAt, now: store.now)
                {
                    Text(recap).aryaText(AryaFont.body, AryaColor.inkMuted)
                        .lineSpacing(AryaSpace.s1)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                OutcomeMetricsPanel(
                    metrics: OutcomeMetrics.build(
                        events: events, steward: steward, state: snapshot.state, now: store.now,
                        statuses: store.outcomeReads[steward]?.metrics,
                        runs: store.outcomeReads[steward]?.runs),
                    now: store.now)
                let reads = store.outcomeReads[steward]
                let impact = reads?.impact.map(OutcomeImpact.build)
                // Each panel drops into the shorter column, so both columns reach RECENT
                // together whatever a steward has to say.
                OutcomeColumns(spacing: AryaSpace.s5, rowSpacing: AryaSpace.s4) {
                    OutcomeNowSection(
                        now: OutcomeNow.build(
                            events: events, steward: steward, state: snapshot.state,
                            now: store.now, live: reads?.live),
                        openRun: openRun, startServing: startServing)
                    OutcomeFindingsSection(
                        findings: OutcomeFinding.build(
                            reads?.findings ?? [], events: events, steward: steward))
                    if let plan = snapshot.plan, !plan.steps.isEmpty {
                        OutcomePlanSection(plan: plan, now: store.now, openRun: openRun)
                    }
                    if let impact { OutcomeImpactSection(impact: impact) }
                    OutcomeKnowsSection(
                        notes: OutcomeContext.build(events: events, steward: steward).notes)
                }
                OutcomeActivitySection(
                    activity: snapshot.activity, now: store.now, openRun: openRun,
                    openApprovals: openApprovals)
                let context = OutcomeContext.build(events: events, steward: steward)
                if !context.isEmpty { OutcomeContextSection(context: context) }
                OutcomeDetails(state: snapshot.state, now: store.now)
                if let error = store.writeError {
                    Text(error).aryaText(AryaFont.caption, AryaColor.negative)
                }
            }
            .padding(.horizontal, AryaSpace.s4)
            .padding(.vertical, AryaSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Panels in two equal columns, each placed under whichever column is shorter so far (in
/// order), so neither column ends with a hole above the next full-width section.
struct OutcomeColumns: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let (_, heights) = place(subviews, width: width)
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let (spots, _) = place(subviews, width: bounds.width)
        let column = (bounds.width - spacing) / 2
        for (subview, spot) in zip(subviews, spots) {
            subview.place(
                at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y), anchor: .topLeading,
                proposal: ProposedViewSize(width: column, height: nil))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> ([CGPoint], [CGFloat]) {
        let column = max(0, (width - spacing) / 2)
        var heights: [CGFloat] = [0, 0]
        var spots: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: column, height: nil))
            let index = heights[1] < heights[0] ? 1 : 0
            let top = heights[index] == 0 ? 0 : heights[index] + rowSpacing
            spots.append(CGPoint(x: index == 0 ? 0 : column + spacing, y: top))
            if size.height > 0 { heights[index] = top + size.height }
        }
        return (spots, heights)
    }
}

/// Success, readiness, autonomy, and next wake, behind a disclosure.
struct OutcomeDetails: View {
    let state: OutcomeState
    let now: Date
    @AryaState private var open: Bool

    /// - Parameter open: start expanded (snapshots render the facts this way).
    init(state: OutcomeState, now: Date, open: Bool = false) {
        self.state = state
        self.now = now
        _open = AryaState(initialValue: open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: AryaSpace.s1) {
                    Text(open ? "▾" : "▸").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    Text("Details").aryaText(AryaFont.overline, AryaColor.inkFaint)
                    if !open {
                        Text(state.readiness.text).aryaText(AryaFont.monoSmall, readinessColor)
                            .padding(.leading, AryaSpace.s2)
                    }
                }
            }
            .buttonStyle(.plain)
            if open {
                OutcomeFact(label: "Success", value: state.success)
                OutcomeFact(label: "Readiness", value: state.readiness.text, color: readinessColor)
                OutcomeFact(label: "Autonomy", value: state.autonomy.text)
                OutcomeSchedule(state: state, now: now)
                if let direction = state.metric?.direction {
                    OutcomeFact(label: "Direction", value: OutcomeText.direction(direction))
                }
            }
        }
    }

    private var readinessColor: Color {
        state.readiness.isReady ? AryaColor.positive : AryaColor.inkMuted
    }
}

/// The steward's current plan as a quiet checklist, with why it last changed. Hidden when
/// the steward has no plan yet.
struct OutcomePlanSection: View {
    let plan: OutcomePlan
    let now: Date
    let openRun: (String) -> Void

    var body: some View {
        OutcomeSection("Plan", trailing: "\(plan.doneCount)/\(plan.activeCount)") {
            ForEach(plan.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(step.status.mark)
                        .aryaText(AryaFont.mono, color(step.status))
                        .accessibilityLabel(step.status.word)
                    Text(step.title)
                        .aryaText(
                            AryaFont.body,
                            step.status == .dropped ? AryaColor.inkFaint : AryaColor.ink
                        )
                        .strikethrough(step.status == .dropped)
                    if let note = step.note {
                        Text(note).aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                }
                .frame(minHeight: AryaSize.outcomeRowHeight)
            }
            if let reason = plan.reason {
                Text("Changed \(AryaTime.label(plan.updated, now: now, style: .long)): \(reason)")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AryaSpace.s1)
            }
        }
    }

    private func color(_ status: OutcomePlan.StepStatus) -> Color {
        switch status {
        case .done: AryaColor.positive
        case .doing: AryaColor.ink
        case .blocked: AryaColor.accent
        case .failed: AryaColor.negative
        case .todo, .dropped: AryaColor.inkFaint
        }
    }
}
