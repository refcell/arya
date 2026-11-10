import AryaDesign
import SwiftUI

/// Text for the recap, kept apart from layout so it can be tested.
enum OutcomeRecapText {
    /// "2 runs ended · 3 actions taken" or "nothing new".
    static func since(_ recap: OutcomeRecap) -> String {
        var parts: [String] = []
        if recap.runsSince > 0 { parts.append(count(recap.runsSince, "run") + " ended") }
        let actions = recap.actionsSince.count
        if actions > 0 { parts.append(count(actions, "action") + " taken") }
        return parts.isEmpty ? "nothing new" : parts.joined(separator: " · ")
    }

    /// "1 approval · 1 question · 2 proposals" or nil when nothing is unresolved.
    static func unresolved(_ recap: OutcomeRecap) -> String? {
        var parts: [String] = []
        if !recap.pending.isEmpty { parts.append(count(recap.pending.count, "approval")) }
        if recap.questions > 0 { parts.append(count(recap.questions, "question")) }
        if recap.failedActions > 0 { parts.append(count(recap.failedActions, "failed action")) }
        if recap.openProposals > 0 { parts.append(count(recap.openProposals, "proposal")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The recap as one paragraph for a person coming back, or nil on a first visit or when
    /// nothing happened and nothing waits.
    static func paragraph(
        _ recap: OutcomeRecap, seenAt: Date?, now: Date, timeZone: TimeZone = .current
    ) -> String? {
        guard let seenAt, now.timeIntervalSince(seenAt) >= OutcomeTime.recapGapSeconds else {
            return nil
        }
        let waiting = unresolved(recap)
        guard recap.runsSince > 0 || !recap.actionsSince.isEmpty || waiting != nil else {
            return nil
        }
        let when = AryaTime.label(seenAt, now: now, style: .long, timeZone: timeZone)
        // A last look older than the newest news by more than a day reads as a date, not a
        // visit the person remembers.
        let stale = recap.newestAt.map { $0.timeIntervalSince(seenAt) > 86_400 } ?? false
        var text = stale ? "Since \(when)" : "Since you looked \(when)"
        let news = since(recap)
        let list = news.replacing(" · ", with: ", ")
        text += news == "nothing new" ? ", nothing new ran." : ": \(list)."
        if let waiting {
            text += " Waiting on you: \(waiting.replacing(" · ", with: ", "))."
        }
        return text
    }

    private static func count(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}

/// What the steward did and why, newest first, one line each.
struct OutcomeActivitySection: View {
    let activity: [OutcomeActivity]
    let now: Date
    let openRun: (String) -> Void
    /// Opens the approval a waiting action is held on.
    let openApprovals: () -> Void
    /// Rows shown before "Show all".
    static let collapsedCount = 12
    @AryaState private var showAll = false
    @AryaState private var expanded: String?

    var body: some View {
        OutcomeSection("Recent", trailing: OutcomeActivityText.tally(activity)) {
            if activity.isEmpty {
                Text("Nothing yet. What the steward does, and why, appears here.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            } else {
                let shown = showAll ? activity : Array(activity.prefix(Self.collapsedCount))
                ForEach(shown) { item in
                    OutcomeActivityRow(
                        item: item, now: now, isExpanded: expanded == item.id, openRun: openRun,
                        toggle: {
                            if item.state == .waiting { return openApprovals() }
                            expanded = expanded == item.id ? nil : item.id
                        })
                }
                if activity.count > Self.collapsedCount {
                    Button(showAll ? "Show fewer" : "Show all \(activity.count)") {
                        showAll.toggle()
                    }
                    .buttonStyle(.aryaTertiary)
                }
            }
        }
    }
}

/// One action on one line: a mark, the action and target in mono, and a muted why. A click
/// opens the approval when it waits on the person, else shows the policy, risk, and run.
struct OutcomeActivityRow: View {
    let item: OutcomeActivity
    let now: Date
    let isExpanded: Bool
    let openRun: (String) -> Void
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(item.state.mark).aryaText(AryaFont.mono, markColor)
                    Text(item.kind).aryaText(AryaFont.mono, AryaColor.ink)
                    if let target = item.target {
                        Text(target).aryaText(AryaFont.mono, AryaColor.inkMuted)
                    }
                    Text(item.reason.isEmpty ? "no reason given" : item.reason)
                        .aryaText(AryaFont.body, AryaColor.inkFaint)
                        .lineLimit(1)
                    Spacer(minLength: AryaSpace.s2)
                    Text(AryaTime.label(item.at, now: now, style: .short))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        .help(AryaTime.absolute(item.at, timeZone: .current))
                }
                .frame(minHeight: AryaSize.outcomeRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(OutcomeActivityText.spoken(item))
            .accessibilityHint(
                item.state == .waiting
                    ? "Opens the approval" : "Shows the policy, risk, and run")
            if !item.writes.isEmpty { writes }
            if isExpanded { detail }
        }
    }

    /// The inline mini diff: what the action writes, green when it was applied, muted while
    /// it waits or was only proposed, struck through when it was refused.
    private var writes: some View {
        let color: Color =
            switch item.state {
            case .executed: AryaColor.positive
            case .failed, .rejected: AryaColor.negative
            case .waiting, .proposed: AryaColor.inkMuted
            }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(item.writes.prefix(2).enumerated()), id: \.offset) { _, line in
                Text("+ " + line)
                    .aryaText(AryaFont.monoSmall, color)
                    .strikethrough(item.state == .rejected || item.state == .failed)
                    .lineLimit(1).truncationMode(.tail)
                    .help(line)
            }
        }
        .padding(.leading, AryaSpace.s4)
        .padding(.bottom, AryaSpace.s1)
        .accessibilityLabel("Writes " + item.writes.joined(separator: "; "))
    }

    private var detail: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(item.state.rawValue).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            if let policy = item.policy { PolicyChip(policy) }
            if let risk = item.risk {
                OutcomePill(
                    text: "risk \(risk)",
                    color: risk == "high" ? AryaColor.negative : AryaColor.inkMuted)
            }
            Button(item.run) { openRun(item.run) }.buttonStyle(.aryaTertiary)
        }
        .padding(.leading, AryaSpace.s4)
    }

    private var markColor: Color {
        switch item.state {
        case .executed: AryaColor.positive
        case .failed, .rejected: AryaColor.negative
        case .waiting: AryaColor.accent
        case .proposed: AryaColor.inkFaint
        }
    }
}

/// Text for the activity feed.
enum OutcomeActivityText {
    /// "✓ 3  ✕ 1  ◷ 1": executed, failed or rejected, and waiting counts.
    static func tally(_ activity: [OutcomeActivity]) -> String? {
        guard !activity.isEmpty else { return nil }
        let done = activity.filter { $0.state == .executed }.count
        let bad = activity.filter { [.failed, .rejected].contains($0.state) }.count
        let waiting = activity.filter { $0.state == .waiting }.count
        var parts = ["✓ \(done)"]
        if bad > 0 { parts.append("✕ \(bad)") }
        if waiting > 0 { parts.append("◷ \(waiting)") }
        return parts.joined(separator: "  ")
    }

    /// "label tracker:ISSUE-7, executed, because Bugs get the bug label."
    static func spoken(_ item: OutcomeActivity) -> String {
        var text = item.kind
        if let target = item.target { text += " \(target)" }
        text += ", \(item.state.rawValue)"
        if !item.reason.isEmpty { text += ", because \(item.reason)" }
        return text
    }
}

extension AryaSize {
    /// Compact row height for the overview's checklist and activity lines.
    static let outcomeRowHeight: CGFloat = 24
}
