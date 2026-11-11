import AryaDesign
import SwiftUI

/// The steward's last finished runs under a run's thread, so a short run sits next to how
/// the same work went before: when, how it ended, its title, steps and time.
struct EarlierRun: Hashable, Sendable, Identifiable {
    var id: String
    var at: Date
    var ok: Bool
    var title: String
    var isDryRun: Bool
    var steps: Int
    var seconds: Double?

    static let limit = 8

    static func list(events: [FeatureEvent], steward: String?, excluding run: String)
        -> [EarlierRun]
    {
        guard let steward else { return [] }
        let ends = events.filter {
            $0.steward == steward && $0.run != run
                && ($0.type == "run.finished" || $0.type == "run.failed")
        }
        return ends.suffix(limit).reversed().compactMap { end -> EarlierRun? in
            guard let id = end.run else { return nil }
            let started = events.first { $0.run == id && $0.type == "run.started" }
            let summary =
                end.payload["summary"]?.string?.split(separator: "\n").first.map(String.init)
                ?? end.payload["reason"]?.string ?? "run"
            let parts = RunTitle.parts(
                summary: summary, dryRun: end.payload["dryRun"]?.bool == true)
            let steps = RunThreadText.steps(RunStream.build(events: events, run: id).steps)
            return EarlierRun(
                id: id, at: started?.at ?? end.at,
                ok: end.type == "run.finished" && end.payload["status"]?.string != "failed",
                title: parts.title, isDryRun: parts.isDryRun, steps: steps.count,
                seconds: started.map { end.at.timeIntervalSince($0.at) })
        }
    }

    /// "4 steps · 2.4 s".
    var meta: String {
        [RunMetrics.count(steps, "step"), seconds.map(FeatureTime.duration)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct EarlierRunsView: View {
    var runs: [EarlierRun]
    var now: Date
    var openRun: ((String) -> Void)?
    /// Wide enough for "12h ago" in mono small.
    private static let timeWidth: CGFloat = 64

    var body: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("EARLIER RUNS").aryaText(AryaFont.label, AryaColor.inkFaint)
                    .padding(.bottom, AryaSpace.s1)
                ForEach(runs) { run in
                    Button {
                        openRun?(run.id)
                    } label: {
                        row(run)
                    }
                    .buttonStyle(.plain)
                    .disabled(openRun == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ run: EarlierRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(FeatureTime.relative(run.at, now: now))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                .frame(width: Self.timeWidth, alignment: .leading)
            MarkGlyph(mark: run.ok ? .ok : .failed)
            Text(run.title).aryaText(AryaFont.body, AryaColor.inkMuted)
                .lineLimit(1).truncationMode(.tail)
            if run.isDryRun { DryRunPill() }
            Spacer(minLength: AryaSpace.s2)
            Text(run.meta).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
