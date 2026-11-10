import AryaDesign
import SwiftUI

/// One open charter proposal as Improve reviews it: what changes and why, how its rehearsal
/// compares with the live charter's case by case, and what a person can do about it.
struct ProposalReview: Hashable, Sendable, Identifiable {
    /// One case whose result changed between the live charter and the proposal.
    struct CaseChange: Hashable, Sendable, Identifiable {
        var id: String
        var before: String
        var after: String
        var beforeDetail: String
        var afterDetail: String
        var better: Bool
    }

    var item: ProposalItem
    /// "Change outcome: security reports were waiting behind billing questions."
    var title: String
    var cases: Int
    var worse: [CaseChange]
    var better: [CaseChange]
    /// The gate has run (both rehearsals recorded).
    var compared: Bool
    /// The charter change as unified diff hunks, with its line counts.
    var diff: ProposalDiff?

    var id: String { item.id }
    var unchanged: Int { max(0, cases - worse.count - better.count) }
    /// Nothing goes live by default: a regression leaves Reject as the only plain action.
    var regressed: Bool { !worse.isEmpty || item.gate?.passed == false }

    static func build(_ item: ProposalItem, events: [FeatureEvent]) -> ProposalReview {
        let gated = events.last {
            $0.type == "proposal.gated" && $0.payload["proposal"]?.string == item.id
        }
        let list = RehearsalList.build(events: events)
        let baseline = list.rehearsals.first { $0.id == gated?.payload["baseline"]?.string }
        let candidate = list.rehearsals.first { $0.id == gated?.payload["candidate"]?.string }
        var worse: [CaseChange] = []
        var better: [CaseChange] = []
        if let baseline, let candidate {
            let before = Dictionary(baseline.cases.map { ($0.id, $0) }) { first, _ in first }
            for after in candidate.cases {
                guard let was = before[after.id], was.passed != after.passed else { continue }
                let change = CaseChange(
                    id: after.id, before: ProposalText.choice(was, events: events),
                    after: ProposalText.choice(after, events: events),
                    beforeDetail: ImproveText.wouldHaveDone(was, events: events),
                    afterDetail: ImproveText.wouldHaveDone(after, events: events),
                    better: after.passed)
                if change.better { better.append(change) } else { worse.append(change) }
            }
        } else {
            worse = (item.gate?.regressions ?? []).map {
                CaseChange(
                    id: $0, before: "", after: "", beforeDetail: "", afterDetail: "", better: false)
            }
        }
        return ProposalReview(
            item: item, title: ProposalText.title(item, events: events),
            cases: candidate?.caseCount ?? baseline?.caseCount ?? 0, worse: worse, better: better,
            compared: gated != nil, diff: ProposalDiff.build(item, events: events))
    }
}

/// A proposal's charter against the live one, as unified diff hunks with two lines of context.
struct ProposalDiff: Hashable, Sendable {
    var text: String
    var added: Int
    var removed: Int

    /// "+3 −1".
    var counts: String { "+\(added) −\(removed)" }

    static let context = 2
    /// Changed lines up to which the diff starts open.
    static let openLimit = 6

    static func build(_ item: ProposalItem, events: [FeatureEvent]) -> ProposalDiff? {
        guard let steward = item.steward,
            let proposed = ProposalText.proposedCharter(item, events: events),
            let live = LiveCharter.find(events: events, steward: steward)?.charter
        else { return nil }
        return between(live, proposed)
    }

    static func between(_ live: FeatureJSON, _ proposed: FeatureJSON) -> ProposalDiff? {
        let old = lines(live)
        let new = lines(proposed)
        let edits = removedFirst(LineDiff.edits(old, new))
        let changed = edits.indices.filter {
            if case .same = edits[$0] { false } else { true }
        }
        guard !changed.isEmpty else { return nil }
        var keep = Set<Int>()
        for index in changed {
            for near in max(0, index - context)...min(edits.count - 1, index + context) {
                keep.insert(near)
            }
        }
        var out = ["--- live", "+++ proposed"]
        var added = 0
        var removed = 0
        var last = -1
        for index in keep.sorted() {
            if last >= 0, index > last + 1 { out.append("@@") }
            last = index
            switch edits[index] {
            case .same(let line): out.append(" " + line)
            case .removed(let line):
                out.append("-" + line)
                removed += 1
            case .added(let line):
                out.append("+" + line)
                added += 1
            }
        }
        return ProposalDiff(text: out.joined(separator: "\n"), added: added, removed: removed)
    }

    /// Within each run of changes, removed lines before added ones, as unified diffs read.
    static func removedFirst(_ edits: [LineDiff.Edit]) -> [LineDiff.Edit] {
        var out: [LineDiff.Edit] = []
        var removed: [LineDiff.Edit] = []
        var added: [LineDiff.Edit] = []
        func flush() {
            out += removed + added
            removed = []
            added = []
        }
        for edit in edits {
            switch edit {
            case .same:
                flush()
                out.append(edit)
            case .removed: removed.append(edit)
            case .added: added.append(edit)
            }
        }
        flush()
        return out
    }

    /// Pretty JSON without the version, which every proposal bumps, and without trailing
    /// commas, so dropping the last member of an object changes one line, not two.
    private static func lines(_ charter: FeatureJSON) -> [String] {
        var plain = charter
        if case .object(var members) = charter {
            members["version"] = nil
            plain = .object(members)
        }
        return plain.prettyText.split(separator: "\n").map {
            $0.hasSuffix(",") ? String($0.dropLast()) : String($0)
        }
    }
}

/// Text for proposal reviews, kept apart from layout so it can be tested.
enum ProposalText {
    /// The change sentence, then the author's why: never the proposal id.
    static func title(_ item: ProposalItem, events: [FeatureEvent]) -> String {
        var lines = item.reason.split(separator: "\n").map(String.init)
        var change = item.title
        if change == item.id || change.isEmpty {
            change = changeSentence(item, events: events)
        }
        if lines.first == item.title { lines.removeFirst() }
        let why = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !why.isEmpty else { return change }
        return "\(change): \(lowerFirst(why))"
    }

    /// The charter a proposal would make live, from its `proposal.created` event.
    static func proposedCharter(_ item: ProposalItem, events: [FeatureEvent]) -> FeatureJSON? {
        events.last {
            $0.type == "proposal.created"
                && ($0.payload["proposal"]?.string ?? $0.payload["id"]?.string) == item.id
        }?.payload["charter"]
    }

    /// "Change guardrails and sign-off", from the proposed charter against the live one.
    static func changeSentence(_ item: ProposalItem, events: [FeatureEvent]) -> String {
        guard let steward = item.steward,
            let proposed = proposedCharter(item, events: events),
            let live = LiveCharter.find(events: events, steward: steward)?.charter
        else { return "Change the charter" }
        let fields: [(String, String)] = [
            ("name", "name"), ("outcome", "outcome"), ("metric", "metric"),
            ("bindings", "connections"), ("guardrails", "guardrails"), ("policy", "sign-off"),
            ("triggers", "schedule"), ("effort", "effort"), ("adapter", "adapter"),
        ]
        let changed = fields.filter { proposed[$0.0] != live[$0.0] }.map(\.1)
        return changed.isEmpty ? "Change the charter" : CharterText.title(changed)
    }

    /// "Rehearsal: 7 of 8 cases unchanged, 1 got worse.", split so "worse" can be toned.
    static func summary(_ review: ProposalReview) -> (lead: String, worse: String, tail: String) {
        guard review.compared else {
            return ("Rehearsing on past work; nothing goes live until it passes.", "", "")
        }
        var lead = "Rehearsal: \(review.unchanged) of \(review.cases) cases unchanged"
        if !review.better.isEmpty { lead += ", \(review.better.count) got better" }
        guard !review.worse.isEmpty else { return (lead + ".", "", "") }
        return (lead + ", \(review.worse.count) got ", "worse", ".")
    }

    /// The case's choice alone ("billing"), for before → after.
    static func choice(_ result: CaseResult, events: [FeatureEvent]) -> String {
        let text = ImproveText.choice(result, events: events)
        return text.hasPrefix("chose ") ? String(text.dropFirst(6)) : text
    }

    /// What the confirm says before accepting over a regression.
    static func confirm(_ review: ProposalReview) -> String {
        let names = review.worse.map(\.id).joined(separator: ", ")
        return "This goes live although \(names) got worse in rehearsal. The override is "
            + "recorded with your name."
    }

    private static func lowerFirst(_ text: String) -> String {
        guard let first = text.first, text.dropFirst().first?.isLowercase ?? true else {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }
}

/// Improve's PROPOSALS: each open proposal as a title, one plain summary line, the cases that
/// changed (each expands to before and after), and its actions. A regressed proposal offers
/// Reject and keeps Accept anyway behind More with a confirm; a passing one offers Accept.
struct OutcomeProposalsSection: View {
    @ObservedObject var store: FeatureStore
    let list: ChangeList
    let events: [FeatureEvent]
    /// The steward's newest live run, which What if replays under a proposal's charter.
    let latestRun: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            Text("Proposals").aryaText(AryaFont.overline, AryaColor.inkFaint)
            if list.open.isEmpty {
                Text(
                    list.closed.isEmpty
                        ? "No proposed changes."
                        : "No open proposals. \(list.closed.count) decided."
                )
                .aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            ForEach(list.open) { item in
                OutcomeProposalRow(
                    store: store, review: ProposalReview.build(item, events: events),
                    latestRun: latestRun)
            }
        }
    }
}

struct OutcomeProposalRow: View {
    @ObservedObject var store: FeatureStore
    let review: ProposalReview
    let latestRun: String?
    @AryaState private var expanded: String?
    @AryaState private var confirming = false
    @AryaState private var whatIf: String?
    /// Short diffs start open; long ones start folded behind their counts.
    @AryaState private var showDiff: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text(review.title).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AryaSpace.s3)
                actions
            }
            summary
            if let diff = review.diff {
                Button {
                    showDiff = !diffOpen(diff)
                } label: {
                    HStack(spacing: AryaSpace.s1) {
                        Text(diffOpen(diff) ? "▾" : "▸")
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        Text("Charter diff").aryaText(AryaFont.caption, AryaColor.inkMuted)
                        Text("+\(diff.added)").aryaText(AryaFont.monoSmall, AryaColor.positive)
                        Text("−\(diff.removed)").aryaText(AryaFont.monoSmall, AryaColor.negative)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Charter diff, \(diff.added) added, \(diff.removed) removed")
                if diffOpen(diff) { DiffBlock(diff.text) }
            }
            ForEach(review.worse + review.better) { change in
                OutcomeCaseChangeRow(
                    change: change, isExpanded: expanded == change.id
                ) { expanded = expanded == change.id ? nil : change.id }
            }
            if let whatIf {
                Text(whatIf).aryaText(AryaFont.body, AryaColor.inkMuted).textSelection(.enabled)
            }
        }
        .confirmationDialog(
            "Accept a change that got worse?", isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Accept anyway", role: .destructive) {
                perform(.overrideProposal(review.id, reason: ProposalText.confirm(review)))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProposalText.confirm(review))
        }
    }

    private var summary: some View {
        let parts = ProposalText.summary(review)
        return
            (Text(parts.lead).foregroundColor(AryaColor.inkMuted)
            + Text(parts.worse).foregroundColor(AryaColor.negative)
            + Text(parts.tail).foregroundColor(AryaColor.inkMuted))
            .aryaText(AryaFont.body, AryaColor.inkMuted)
    }

    @ViewBuilder private var actions: some View {
        if review.regressed {
            Button("Reject") { reject() }.buttonStyle(.aryaSecondary)
            more(acceptAnyway: true)
        } else if review.item.canAccept {
            Button("Reject") { reject() }.buttonStyle(.aryaTertiary)
            more(acceptAnyway: false)
            Button("Accept") { perform(.acceptProposal(review.id)) }
                .buttonStyle(.aryaPrimary)
                .help("The change goes live.")
        } else {
            Button("Reject") { reject() }.buttonStyle(.aryaTertiary)
            more(acceptAnyway: false)
        }
    }

    private func more(acceptAnyway: Bool) -> some View {
        Menu("More") {
            if let latestRun {
                Button("What if… (replay the latest run)") { ask(latestRun) }
            }
            if acceptAnyway, review.item.canOverride {
                Button("Accept anyway…") { confirming = true }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .aryaText(AryaFont.caption, AryaColor.inkMuted)
    }

    private func diffOpen(_ diff: ProposalDiff) -> Bool {
        showDiff ?? (diff.added + diff.removed <= ProposalDiff.openLimit)
    }

    private func reject() { perform(.rejectProposal(review.id, reason: "")) }

    private func perform(_ write: FeatureWrite) {
        Task { await store.perform(write) }
    }

    private func ask(_ run: String) {
        whatIf = "Replaying…"
        Task {
            do {
                whatIf = try await store.workspace.whatIf(run: run, proposal: review.id)
            } catch {
                whatIf = FeatureStore.describe(error)
            }
        }
    }
}

/// A case that changed: id and before → after choice; expands to both full results.
struct OutcomeCaseChangeRow: View {
    let change: ProposalReview.CaseChange
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(isExpanded ? "▾" : "▸")
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    Text(change.id).aryaText(AryaFont.mono, AryaColor.ink)
                    if !change.before.isEmpty || !change.after.isEmpty {
                        Text("\(change.before) → \(change.after)")
                            .aryaText(AryaFont.mono, AryaColor.inkMuted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(change.better ? "better" : "worse")
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(change.id), \(change.better ? "better" : "worse")")
            if isExpanded {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    detail("Live charter", change.beforeDetail)
                    detail("Proposed", change.afterDetail)
                }
                .padding(.leading, AryaSpace.s5)
            }
        }
    }

    private func detail(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(label).aryaText(AryaFont.caption, AryaColor.inkFaint)
                .frame(width: AryaSize.backtestLabel, alignment: .leading)
            Text(text.isEmpty ? "not recorded" : text)
                .aryaText(AryaFont.monoSmall, AryaColor.ink)
                .textSelection(.enabled)
        }
    }
}

extension AryaSize {
    static let backtestLabel: CGFloat = 88
}
