import AryaDesign
import SwiftUI

/// The inspector for a selected approval: whose it is, the run it came from (a link to its
/// thread), why policy held it in the workspace's words, its risk, and earlier decisions on
/// the same target.
struct ApprovalInspector: View {
    @ObservedObject var store: FeatureStore
    var approval: String
    var openRun: ((String, String) -> Void)?
    /// Off where the approval block above already states the policy (Needs you detail).
    var showsPolicy = true

    var body: some View {
        if case .loaded(let events) = store.state,
            let facts = ApprovalFacts.build(events: events, approval: approval)
        {
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                Text(facts.title).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                field("Steward", facts.steward)
                if let run = facts.run {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Run").aryaText(AryaFont.label, AryaColor.inkFaint)
                        if let openRun, let steward = facts.stewardID {
                            Button(facts.runTitle) { openRun(run, steward) }
                                .buttonStyle(.aryaTertiary)
                                .help("Open this run's thread")
                        } else {
                            Text(facts.runTitle).aryaText(AryaFont.body, AryaColor.ink)
                        }
                    }
                }
                if showsPolicy, let policy = store.approvalTexts[approval]?.policy, !policy.isEmpty
                {
                    field("Why it waits", policy)
                }
                field("Risk", facts.risk)
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("Earlier on \(facts.target)").aryaText(AryaFont.label, AryaColor.inkFaint)
                    if facts.earlier.isEmpty {
                        Text("No earlier decisions.").aryaText(AryaFont.caption, AryaColor.inkMuted)
                    }
                    ForEach(facts.earlier, id: \.self) {
                        Text($0).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                    }
                }
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).aryaText(AryaFont.label, AryaColor.inkFaint)
            Text(value).aryaText(AryaFont.body, AryaColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the approval inspector shows, projected from the ledger.
struct ApprovalFacts: Hashable, Sendable {
    var title: String
    var steward: String
    var stewardID: String?
    var run: String?
    var runTitle: String
    var target: String
    var risk: String
    /// Earlier decided approvals on the same target, newest first: "granted · reply · Nov 8".
    var earlier: [String]

    static func build(events: [FeatureEvent], approval: String, now: Date = Date())
        -> ApprovalFacts?
    {
        let queue = ApprovalQueue.build(events: events)
        guard let item = (queue.pending + queue.decided).first(where: { $0.id == approval })
        else { return nil }
        let names = StewardNames.build(events: events)
        let earlier = queue.decided.filter {
            $0.id != approval && $0.target == item.target && !item.target.isEmpty
        }
        .sorted { $0.requestedAt > $1.requestedAt }
        .compactMap { other -> String? in
            guard let decision = other.decision else { return nil }
            return [
                decision.verdict.rawValue, other.kind, LedgerTable.actorLabel(decision.actor),
                AryaTime.label(decision.at, now: now, style: .short),
            ].joined(separator: " · ")
        }
        return ApprovalFacts(
            title: item.kind == "question" ? item.summary : "\(item.kind) \(item.target)",
            steward: item.steward.map { names[$0] ?? $0 } ?? "—", stewardID: item.steward,
            run: item.run,
            runTitle: item.run.map { RunStream.build(events: events, run: $0).title } ?? "—",
            target: item.target.isEmpty ? "this target" : item.target,
            risk: ActionRisk(kind: item.kind).rawValue, earlier: earlier)
    }
}
