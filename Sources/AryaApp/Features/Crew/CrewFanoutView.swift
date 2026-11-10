import AryaDesign
import SwiftUI

/// The fan-out of a crew run in the run inspector: the host and each delegate with its status,
/// current step, duration, and outcome. It follows the store's live events and ticks the
/// running durations each second; a preview workspace keeps its fixed clock.
struct CrewFanoutView: View {
    @ObservedObject var store: FeatureStore
    let run: String

    var body: some View {
        let live =
            CrewFanout.build(events: store.events, run: run, now: store.now)?.host.state
            == .running
        if live && !(store.workspace is PreviewWorkspace) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                tree(now: max(context.date, store.now))
            }
        } else {
            tree(now: store.now)
        }
    }

    @ViewBuilder
    private func tree(now: Date) -> some View {
        if let fanout = CrewFanout.build(events: store.events, run: run, now: now) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack(spacing: AryaSpace.s2) {
                    Text("CREW").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Text(CrewFanoutText.tally(fanout))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
                node(fanout.host, branch: nil)
                ForEach(Array(fanout.children.enumerated()), id: \.element.id) { index, child in
                    node(child, branch: index == fanout.children.count - 1 ? "└─" : "├─")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Crew fan-out")
        }
    }

    private func node(_ node: CrewFanout.Node, branch: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s1) {
            if let branch {
                Text(branch).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    StatusDot(Self.status(node.state))
                    Text(node.title)
                        .aryaText(
                            branch == nil ? AryaFont.bodyStrong : AryaFont.caption, AryaColor.ink
                        )
                        .lineLimit(1)
                    Spacer(minLength: AryaSpace.s2)
                    Text(CrewFanoutText.duration(node.seconds))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
                if let detail = Self.detail(node) {
                    Text(detail.text)
                        .aryaText(AryaFont.monoSmall, detail.color)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, AryaSpace.s1)
        .accessibilityElement(children: .combine)
    }

    /// The running step, or the outcome once settled.
    private static func detail(_ node: CrewFanout.Node) -> (text: String, color: Color)? {
        switch node.state {
        case .running, .waiting:
            return node.step.map { ($0, AryaColor.accent) }
        case .completed:
            return node.outcome.map { ($0, AryaColor.inkMuted) }
        case .failed:
            return ("failed: " + (node.outcome ?? "unknown"), AryaColor.negative)
        case .refused:
            return ("refused: " + CrewText.refusal(node.outcome ?? ""), AryaColor.negative)
        }
    }

    private static func status(_ state: CrewFanout.Node.State) -> AryaStatus {
        switch state {
        case .running: .running
        case .waiting: .waiting
        case .completed: .done
        case .failed: .failed
        case .refused: .denied
        }
    }
}
