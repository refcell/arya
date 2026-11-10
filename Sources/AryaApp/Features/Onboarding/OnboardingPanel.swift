import AryaDesign
import SwiftUI

/// The Overview's lead while a steward is not ready: three numbered steps, the current one
/// expanded with its action (import history, the review queue inline, rehearse or mark ready).
struct OnboardingPanel: View {
    @ObservedObject var store: FeatureStore
    let steward: String
    let steps: OnboardingSteps
    @AryaState private var importing: String?
    @AryaState private var imported: String?

    var body: some View {
        OutcomeSection("Getting to know your team", trailing: progress) {
            ForEach(steps.steps) { step in
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Text(step.done ? "✓" : "\(step.stage.rawValue + 1)")
                            .aryaText(
                                AryaFont.monoSmall,
                                step.done ? AryaColor.positive : AryaColor.inkMuted
                            )
                            .frame(width: AryaSpace.s3, alignment: .leading)
                        Text(step.title)
                            .aryaText(
                                AryaFont.bodyStrong,
                                step.stage == steps.current ? AryaColor.ink : AryaColor.inkMuted)
                        Text(step.detail).aryaText(AryaFont.caption, AryaColor.inkMuted)
                            .lineLimit(1)
                            .help(step.detail)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: AryaSize.rowHeight)
                    if step.stage == steps.current { action(step.stage) }
                }
            }
        }
    }

    private var progress: String {
        "\(steps.steps.filter(\.done).count) of \(steps.steps.count)"
    }

    @ViewBuilder private func action(_ stage: OnboardingSteps.Stage) -> some View {
        Group {
            switch stage {
            case .learn:
                HStack(spacing: AryaSpace.s2) {
                    ForEach(steps.historyBindings, id: \.self) { binding in
                        Button(importing == binding ? "Importing…" : "Import from \(binding)") {
                            importHistory(binding)
                        }
                        .buttonStyle(.aryaPrimary)
                        .disabled(importing != nil)
                    }
                    if let imported {
                        Text(imported).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    }
                }
            case .review:
                if let queue = store.reviewQueues[steward] {
                    ReviewQueuePanel(store: store, steward: steward, queue: queue)
                }
            case .live:
                HStack(spacing: AryaSpace.s2) {
                    if steps.passed, let rehearsal = steps.rehearsal,
                        let version = steps.charterVersion
                    {
                        Button("Mark ready") {
                            Task {
                                await store.perform(
                                    .markReady(
                                        steward: steward, charterVersion: version,
                                        rehearsal: rehearsal))
                            }
                        }
                        .buttonStyle(.aryaPrimary)
                    }
                    let title = steps.rehearsal == nil ? "Rehearse on past work" : "Rehearse again"
                    if steps.passed {
                        Button(title, action: rehearse).buttonStyle(.aryaTertiary)
                    } else {
                        Button(title, action: rehearse).buttonStyle(.aryaPrimary)
                    }
                }
            }
        }
        .padding(.leading, AryaSpace.s3 + AryaSpace.s2)
        .padding(.bottom, AryaSpace.s1)
    }

    private func rehearse() {
        Task { await store.perform(.rehearse(steward: steward, casebook: nil)) }
    }

    private func importHistory(_ binding: String) {
        importing = binding
        Task {
            do {
                imported = try await store.workspace.importHistory(
                    steward: steward, binding: binding)
            } catch {
                imported = "The import failed: \(error.localizedDescription)"
            }
            importing = nil
            await store.reload()
            store.reviewQueues[steward] = try? await store.workspace.reviewQueue(steward: steward)
        }
    }
}
