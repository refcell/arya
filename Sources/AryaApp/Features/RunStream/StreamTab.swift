import AryaDesign
import SwiftUI

/// The Stream tab: Run now and Replay above the selected run's stream.
struct StreamTab: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    var run: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                RunControls(store: store, steward: steward, run: run).id(run)
            }
            .padding(.horizontal, AryaSpace.s5)
            .padding(.top, AryaSpace.s3)
            if let run {
                RunStreamView(store: store, run: run)
            } else {
                EmptyState(
                    "No runs yet.",
                    guidance: "A run starts when a trigger fires or you start one with Run now.")
            }
        }
    }
}

/// Start a manual run, and replay the selected run once it has ended.
private struct RunControls: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    var run: String?
    @AryaState private var input = ""
    @AryaState private var replay: FeatureReplayResult?
    @AryaState private var replayProblem: String?
    @AryaState private var replaying = false

    @AryaState private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(spacing: AryaSpace.s3) {
                Spacer()
                if run != nil {
                    Menu("More") {
                        Button(replaying ? "Replaying" : "Replay this run") { replayRun() }
                            .disabled(!ended || replaying)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .help("Replay re-runs the run from the ledger alone and compares.")
                }
                Button("Run now…") { asking = true }
                    .buttonStyle(.aryaSecondary)
                    .popover(isPresented: $asking, arrowEdge: .bottom) { runNow }
            }
            if let replayProblem {
                Text(replayProblem).aryaText(AryaFont.caption, AryaColor.negative)
            }
            if let replay { ReplayReport(result: replay) }
        }
    }

    private var runNow: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("Start a run now").aryaText(AryaFont.bodyStrong, AryaColor.ink)
            CharterTextField(placeholder: "What should it work on? (optional)", text: $input)
                .frame(width: AryaSize.readingWidth / 2)
            HStack {
                Spacer()
                Button("Cancel") { asking = false }.buttonStyle(.aryaTertiary)
                    .keyboardShortcut(.cancelAction)
                Button("Start run") {
                    asking = false
                    start()
                }
                .buttonStyle(.aryaPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AryaSpace.s4)
    }

    private var ended: Bool {
        guard let run, case .loaded(let events) = store.state else { return false }
        return RunStream.build(events: events, run: run).status != .running
    }

    private func start() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await store.perform(.startRun(steward: steward, input: text)) { input = "" }
        }
    }

    private func replayRun() {
        guard let run else { return }
        replaying = true
        replayProblem = nil
        Task {
            do {
                replay = try await store.workspace.replay(run: run)
            } catch {
                replay = nil
                replayProblem = FeatureStore.describe(error)
            }
            replaying = false
        }
    }
}

/// The replay verdict and, on a divergence, the recorded and replayed events.
private struct ReplayReport: View {
    var result: FeatureReplayResult

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(spacing: AryaSpace.s2) {
                StatusBadge(result.divergences.isEmpty ? .passed : .failed)
                Text(ReplayText.summary(result)).aryaText(AryaFont.body, AryaColor.ink)
            }
            if let first = result.divergences.first {
                Text("Recorded").aryaText(AryaFont.caption, AryaColor.inkMuted)
                CodeBlock(first.recorded)
                Text("Replayed").aryaText(AryaFont.caption, AryaColor.inkMuted)
                CodeBlock(first.replayed)
            }
        }
    }
}

/// Text for replay results, kept apart from layout so it can be tested.
enum ReplayText {
    static func summary(_ result: FeatureReplayResult) -> String {
        guard let first = result.divergences.first else {
            return "Replayed \(result.events) events with no divergence."
        }
        let seq = first.seq.map { ", seq \($0)" } ?? ""
        return "Diverged at event \(first.index + 1) of \(result.events) (\(first.type)\(seq)), "
            + "field \(first.field)."
    }
}
