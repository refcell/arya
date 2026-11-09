import AryaDesign
import SwiftUI

/// The Stream tab: Run now and Replay above the selected run's stream.
struct StreamTab: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    var run: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                StewardOverviewLine(store: store, steward: steward)
                RunControls(store: store, steward: steward, run: run).id(run)
            }
            .padding(AryaSpace.s5)
            .aryaHairline(edge: .bottom)
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

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            HStack(spacing: AryaSpace.s3) {
                CharterTextField(placeholder: "Input for a manual run (optional)", text: $input)
                Button("Run now") { start() }
                    .buttonStyle(.aryaSecondary)
                    .help("Start a run now, as the manual trigger would.")
                if run != nil {
                    Button(replaying ? "Replaying" : "Replay") { replayRun() }
                        .buttonStyle(.aryaTertiary)
                        .disabled(!ended || replaying)
                        .help(
                            ended
                                ? "Re-run from the ledger alone and compare with the recording."
                                : "Replay is available once the run ends.")
                }
            }
            if let replayProblem {
                Text(replayProblem).aryaText(AryaFont.body, AryaColor.negative)
            }
            if let replay { ReplayReport(result: replay) }
        }
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
