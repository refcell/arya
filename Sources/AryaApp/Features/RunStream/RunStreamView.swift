import AryaDesign
import SwiftUI

/// The run stream: one run's steps in order, updating live while the run is in progress.
struct RunStreamView: View {
    @ObservedObject var store: FeatureStore
    var run: String
    var accessory = AnyView(EmptyView())
    /// Opens another run's thread (a crew child, a join's parent); nil where navigation is
    /// not available.
    var openRun: ((String) -> Void)? = nil
    /// The work tab to open on (snapshots); nil opens the first tab with something in it.
    var initialTab: WorkTab? = nil
    @Environment(\.initialWorkTab) private var environmentTab
    /// The tab picked by the person.
    @AryaState private var pickedTab: WorkTab?
    @AryaState private var selection: String?
    @AryaState private var composerFocus = 0
    @AryaState private var following = true
    /// The step to open on (snapshots); nil selects nothing.
    var initialSelection: String? = nil
    @FocusState private var paneFocused: Bool

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading the run.", guidance: "Reading the ledger.")
        case .failed(let message):
            EmptyState(
                "The run could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            let stream = RunStream.build(events: events, run: run)
            let work = RunWork.build(stream: stream, events: events)
            // A live run's clock ticks each second (elapsed, running… counters); snapshots and
            // finished runs use the store's time.
            if stream.status == .running, !AryaMotion.frozenByProcess {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(stream, work: work, now: context.date)
                }
            } else {
                content(stream, work: work, now: store.now)
            }
        }
    }

    @ViewBuilder
    private func content(_ stream: RunStream, work: RunWork, now: Date) -> some View {
        if stream.steps.isEmpty {
            EmptyState(
                "No steps yet.",
                guidance: "Steps appear here as the run reads, decides, and proposes.")
        } else {
            VStack(spacing: 0) {
                RunHeader(
                    stream: stream, accessory: accessory, now: now,
                    facts: store.runFacts[run]
                )
                .padding(.horizontal, AryaSpace.s4)
                .padding(.vertical, AryaSpace.s2)
                AryaHairline()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        RunBriefView(
                            brief: RunBrief.build(
                                stream: stream, events: store.events,
                                expected: store.runFacts[run]?.estimatedSteps
                                    ?? stream.progress?.expected),
                            reading: stream.reading, openRun: openRun
                        )
                        .padding(.horizontal, AryaSpace.s4)
                        .padding(.vertical, AryaSpace.s3)
                        AryaHairline()
                        ScrollView {
                            RunThread(
                                stream: stream, now: now, context: context(stream),
                                showsHeader: false, showsInput: false,
                                selection: selectionBinding
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AryaSpace.s4)
                            .padding(.vertical, AryaSpace.s3)
                        }
                        if let steward = stream.steward {
                            Composer(
                                store: store, steward: steward, focusRequest: composerFocus)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    AryaHairline(.vertical)
                    WorkPane(
                        store: store, work: work, running: stream.status == .running,
                        tab: tabBinding(work), selection: selectionBinding,
                        following: $following
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .background(AryaColor.canvas)
            .focusable()
            .focusEffectDisabled()
            .focused($paneFocused)
            .onAppear { paneFocused = true }
            .onKeyPress(characters: RunKeys.handled) { press in
                switch RunKeys.action(for: press.characters) {
                case .next?:
                    selectionBinding.wrappedValue = RunKeys.step(stream, from: selection, by: 1)
                case .previous?:
                    selectionBinding.wrappedValue = RunKeys.step(stream, from: selection, by: -1)
                case .compose?: composerFocus += 1
                case .tab(let tab)?: pickedTab = tab
                case .follow?: following.toggle()
                case nil: return .ignored
                }
                return .handled
            }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                // ↵ opens the step's diff when it changed something, else its block.
                pickedTab = work.diffs.contains { $0.id == selection } ? .diff : .tools
                selectionBinding.wrappedValue = nil
                selectionBinding.wrappedValue = selection
                return .handled
            }
            .onKeyPress(.escape) {
                guard selection != nil || pickedTab != nil else { return .ignored }
                selection = nil
                pickedTab = nil
                return .handled
            }
            .onAppear { if selection == nil { selection = initialSelection } }
            .task(id: run) { await store.loadRunFacts(run) }
            .task(id: stream.status == .running ? run : nil) {
                // Still frames (tests, snapshots) never follow the ledger (see RootView).
                guard stream.status == .running, !AryaMotion.frozenByProcess else { return }
                // Steps appear and output appends as the ledger grows; ends with the run.
                for await _ in store.workspace.observeRun(run) {
                    await store.reload()
                    await store.loadRunFacts(run)
                }
                await store.loadRunFacts(run)
            }
        }
    }

    private func tabBinding(_ work: RunWork) -> Binding<WorkTab> {
        Binding(
            get: {
                pickedTab ?? initialTab ?? environmentTab ?? WorkTab.allCases.first {
                    work.count($0) > 0
                }
                    ?? .tools
            },
            set: { pickedTab = $0 })
    }

    /// Selecting a work step shows its block on the Tools tab.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selection },
            set: { id in
                selection = id
                if id != nil, pickedTab != .diff { pickedTab = .tools }
            })
    }

    private func context(_ stream: RunStream) -> StepContext {
        StepContext(
            steward: stream.steward, run: stream.run, store: store, openRun: openRun
        ) { write in
            Task { await store.perform(write) }
        }
    }
}

/// What a step needs beyond its own data: where it lives and how to record a decision.
struct StepContext {
    var steward: String?
    var run: String
    var store: FeatureStore? = nil
    var openRun: ((String) -> Void)? = nil
    var decide: (FeatureWrite) -> Void
}

extension RunStatus {
    /// The design-system status shown as a dot and a word.
    var aryaStatus: AryaStatus {
        switch self {
        case .running: return .running
        case .finished: return .done
        case .failed: return .failed
        }
    }
}

private struct StatusLine: View {
    var status: RunStatus

    var body: some View {
        HStack(spacing: AryaSpace.s2) {
            StatusBadge(status.aryaStatus)
            if case .finished(_, let summary) = status, !summary.isEmpty {
                Text(summary).aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Titles and spoken labels for steps, kept apart from layout so they can be tested.
enum StreamStepText {
    /// The short label before a step's title (`tool`, `Decision`), or nil.
    static func label(_ kind: StreamStep.Kind) -> String? {
        switch kind {
        case .toolCall: return "tool"
        case .decision: return "Decision"
        case .action: return "action"
        case .thinking: return "thinking"
        default: return nil
        }
    }

    /// The step's title.
    static func title(_ kind: StreamStep.Kind) -> String {
        switch kind {
        case .started(let trigger): return "Started by \(trigger) trigger"
        case .message(let role, let text): return role == "user" ? "You: \(text)" : text
        case .thinking(let text): return text
        case .status(let state, let detail): return detail.isEmpty ? state : detail
        case .error(let message): return "Error: \(message)"
        case .toolCall(let call): return call.tool
        case .decision(_, let choice, _, _): return choice
        case .action(let action): return "\(action.kind) \(action.target)"
        case .finished(let status, let summary): return summary.isEmpty ? status : summary
        case .failed(let reason): return "Run failed: \(reason)"
        case .delegated(let step): return "↳ " + CrewText.line(step)
        }
    }

    /// The caption describing an action's outcome.
    static func outcome(_ outcome: ActionOutcome) -> String {
        switch outcome {
        case .proposed: return "Proposed"
        case .awaitingApproval: return "Waiting for approval"
        case .approved: return "Approved, running"
        case .executed: return "Ran"
        case .failed(let error): return "failed: \(error)"
        case .rejected(let rule): return "Blocked by \(rule)"
        case .denied(_, let reason): return reason.isEmpty ? "Denied" : "Denied: \(reason)"
        }
    }

    /// The approval card data for an action waiting in this stream.
    static func approval(
        _ action: ProposedActionStep, _ approval: String, step: StreamStep, context: StepContext
    ) -> ApprovalItem {
        ApprovalItem(
            id: approval, actionID: action.actionID, kind: action.kind, target: action.target,
            summary: action.summary, rationale: action.rationale, steward: context.steward,
            run: context.run, requestedAt: step.at)
    }

    /// Whether the step is still in progress: a tool call without its result.
    static func isRunning(_ kind: StreamStep.Kind) -> Bool {
        if case .toolCall(let call) = kind { return !call.finished }
        return false
    }

    /// "ok · 1.2 s", "failed · 850 ms", or "running" for a tool call, after the binding and
    /// source when the binding proxy recorded them: "tracker · live · ok · 1.2 s".
    static func toolCaption(_ call: ToolCallStep) -> String {
        var parts = [call.binding, call.source.map(sourceWord)].compactMap { $0 }
        guard call.finished else { return (parts + ["running"]).joined(separator: " · ") }
        parts.append(call.isError ? "failed" : "ok")
        if let seconds = call.durationSeconds { parts.append(FeatureTime.duration(seconds)) }
        return parts.joined(separator: " · ")
    }

    static func sourceWord(_ source: String) -> String {
        source == "unanswered" ? "no recording, a leak" : source
    }

    /// "routine label-duplicates · 1a2b3c · exited 0"; other endings: "timed out", "signal 9".
    static func routineCaption(_ run: RoutineRun) -> String {
        let ending: String
        switch run.status {
        case "exited": ending = "exited \(run.exitCode ?? 0)"
        case "signaled": ending = "killed by signal \(run.signal ?? 0)"
        case "timed_out": ending = "timed out"
        default: ending = run.status
        }
        let parts = [
            "routine \(run.name)", RoutinesText.shortVersion(run.version), ending,
            run.truncated ? "output truncated" : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// "via tracker · executed", the outcome after the binding the action goes through.
    static func actionCaption(_ action: ProposedActionStep) -> String {
        [action.binding.map { "via \($0)" }, outcome(action.outcome)].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The VoiceOver label: "Step 4, decision, bug, 2m ago".
    static func spoken(_ step: StreamStep, now: Date) -> String {
        let parts = [
            "Step \(step.number)", label(step.kind)?.lowercased(), title(step.kind),
            FeatureTime.relative(step.at, now: now),
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

struct ToolCallBody: View {
    var call: ToolCallStep

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AryaSpace.s2) {
                CodeBlock(call.input.compactText)
                if let output = call.output { CodeBlock(output.compactText) }
            }
        } label: {
            Text(StreamStepText.toolCaption(call))
                .aryaText(AryaFont.caption, call.isError ? AryaColor.negative : AryaColor.inkFaint)
        }
    }
}

/// A routine's result: caption, then standard output and error when there is any.
struct RoutineRunBody: View {
    var run: RoutineRun

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AryaSpace.s2) {
                if !run.stdout.isEmpty { CodeBlock(run.stdout) }
                if !run.stderr.isEmpty {
                    Text("Standard error").aryaText(AryaFont.caption, AryaColor.inkMuted)
                    CodeBlock(run.stderr)
                }
                if run.stdout.isEmpty && run.stderr.isEmpty {
                    Text("No output.").aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
            }
        } label: {
            Text(StreamStepText.routineCaption(run)).aryaText(AryaFont.caption, AryaColor.inkFaint)
        }
    }
}

/// Keyboard rules for the run screen: j/k move between work steps, c focuses the composer.
enum RunKeys {
    enum Action: Equatable {
        case next, previous, compose, follow
        case tab(WorkTab)
    }

    static let handled = CharacterSet(charactersIn: "jkcf1234")

    static func action(for characters: String) -> Action? {
        switch characters {
        case "j": .next
        case "k": .previous
        case "c": .compose
        case "f": .follow
        default: Int(characters).flatMap(WorkTab.init(rawValue:)).map(Action.tab)
        }
    }

    /// The work step `delta` away from `current`, clamped; the first step when none is selected.
    static func step(_ stream: RunStream, from current: String?, by delta: Int) -> String? {
        let ids = stream.steps.filter { RunWork.isWork($0.kind) }.map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}
