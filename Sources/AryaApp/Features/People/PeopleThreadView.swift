import AryaDesign
import SwiftUI

/// A person's conversation with the steward on the People page: their messages and the
/// steward's replies, oldest first, then a composer that writes as that person ("Message as
/// Sam") with Ask, Correct, or Hand off.
struct PersonThreadView: View {
    @ObservedObject var store: FeatureStore
    let steward: String
    let person: PeopleDirectory.Person
    /// The steward's name, for its lines.
    let stewardName: String

    @AryaState private var text = ""
    @AryaState private var intent = MessageIntent.ask
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let thread = PeopleThread(
            events: store.events, steward: steward, person: person.id,
            conversation: store.conversations[key])
        let titles = LedgerTable.runTitles(store.events)
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            if thread.entries.isEmpty {
                Text(PeopleThreadText.empty(person.name))
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(thread.entries) {
                entry(person, $0, titles: titles)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let working = thread.working { workingLine(working) }
            composer
        }
        .padding(.leading, AryaSpace.s4)
        .overlay(alignment: .leading) {
            Rectangle().fill(AryaColor.rule).frame(width: 1)
        }
        .animation(AryaMotion.appear(reduceMotion: reduceMotion), value: thread.entries.count)
        .task(id: "\(key)#\(store.events.count)") {
            // The facade's thread; without one (previews, older homes) the ledger fold stays.
            if let entries = try? await store.workspace.conversation(
                steward: steward, person: person.id)
            {
                store.conversations[key] = entries
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation with \(person.name)")
    }

    /// The steward at work on this person's message: a live dot, what it is doing, the run,
    /// and how long it has been going.
    private func workingLine(_ working: PeopleThread.Working) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            StatusDot(.running)
            Text(stewardName).aryaText(AryaFont.bodyStrong, AryaColor.accent)
            Text(working.doing + "…").aryaText(AryaFont.mono, AryaColor.inkMuted)
            Text("step \(working.steps)")
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            Spacer()
            Text(FeatureTime.relative(working.since, now: store.now))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Steward is working: \(working.doing)")
    }

    private func entry(
        _ person: PeopleDirectory.Person, _ entry: PeopleThread.Entry, titles: [String: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(entry.inbound ? person.name : stewardName)
                    .aryaText(AryaFont.bodyStrong, entry.inbound ? AryaColor.ink : AryaColor.accent)
                if let tag = PeopleThreadText.tag(entry) {
                    Text(tag).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
                if let title = entry.run.flatMap({ titles[$0] }) {
                    Text(title).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
                }
                Spacer()
                Text(FeatureTime.relative(entry.at, now: store.now))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            Text(entry.text.isEmpty ? "(no text)" : entry.text)
                .aryaText(AryaFont.body, entry.text.isEmpty ? AryaColor.inkFaint : AryaColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            AryaSegmented(
                MessageIntent.allCases.map { ($0, $0.label) }, selection: intent
            ) { intent = $0 }
            TextField(PeopleThreadText.placeholder(person.name), text: $text)
                .textFieldStyle(.plain)
                .aryaText(AryaFont.body, AryaColor.ink)
                .padding(.horizontal, AryaSpace.s2)
                .padding(.vertical, AryaSpace.s1)
                .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
                .frame(maxWidth: .infinity)
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(.aryaSecondary)
                .disabled(trimmed.isEmpty)
        }
        .padding(.top, AryaSpace.s1)
    }

    private var key: String { "\(steward)/\(person.id)" }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmed.isEmpty else { return }
        let write = FeatureWrite.message(
            steward: steward, text: trimmed, intent: intent, by: person.id)
        Task { if await store.perform(write) { text = "" } }
    }
}

/// The inspector for a person selected on People: how to reach them, what they may approve,
/// and the work they handed off with the status of the run that took it.
struct PersonInspector: View {
    @ObservedObject var store: FeatureStore
    let steward: String
    let person: String

    /// What stewards learned from this person, from any steward: their corrections and notes,
    /// each with the steward that keeps it.
    @ViewBuilder
    private func learned(_ name: String) -> some View {
        let items = PeopleLearned(events: store.events, person: person).live
        let stewards = StewardNames.build(events: store.events)
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                Text("LEARNED FROM \(name.uppercased())")
                    .aryaText(AryaFont.label, AryaColor.inkFaint)
                if !items.isEmpty {
                    Text("\(items.count)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            if items.isEmpty {
                Text("Nothing yet. Their corrections become notes every run reads.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(items.prefix(5)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(3)
                    Text(
                        [
                            item.source,
                            item.steward.map { stewards[$0] ?? $0 },
                            FeatureTime.relative(item.at, now: store.now),
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    var body: some View {
        let directory = PeopleDirectory(events: store.events, steward: steward)
        if let found = directory.people.first(where: { $0.id == person }) {
            let thread = PeopleThread(
                events: store.events, steward: steward, person: person,
                conversation: store.conversations["\(steward)/\(person)"])
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text(found.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                    if let role = found.role {
                        Text(role).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    }
                }
                fact("Reach", found.reach)
                if let approves = PeopleText.approves(found.approves, prefix: "") {
                    fact("Approves", approves)
                }
                // The counts are this steward's thread; name it, since a person may work with
                // several and the All stewards row sums them.
                fact(
                    "Messages",
                    PeopleThreadText.counts(thread) + " with "
                        + (directory.live?.charter["name"]?.string ?? steward))
                if let reports = PeopleThreadText.reports(thread, now: store.now) {
                    fact("Reports", reports)
                }
                learned(found.name)
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("HANDED OFF").aryaText(AryaFont.label, AryaColor.inkFaint)
                    if thread.tasks.isEmpty {
                        Text("Nothing yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                    ForEach(thread.tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            Text(task.status.label)
                                .aryaText(AryaFont.monoSmall, Self.color(task.status))
                                .frame(width: 96, alignment: .leading)
                            Text(task.text).aryaText(AryaFont.caption, AryaColor.ink)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("LAST MESSAGES").aryaText(AryaFont.label, AryaColor.inkFaint)
                    let recent = thread.entries.filter { $0.action != "report" }.suffix(3)
                    if recent.isEmpty {
                        Text("None yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                    ForEach(Array(recent.reversed())) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            Text(entry.inbound ? found.name : "steward")
                                .aryaText(
                                    AryaFont.monoSmall,
                                    entry.inbound ? AryaColor.inkMuted : AryaColor.accent
                                )
                                .frame(width: 56, alignment: .leading)
                            Text(entry.text).aryaText(AryaFont.caption, AryaColor.ink)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Text(FeatureTime.relative(entry.at, now: store.now))
                                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    static func color(_ status: PeopleThread.Status) -> Color {
        switch status {
        case .done: AryaColor.positive
        case .failed: AryaColor.negative
        case .waiting: AryaColor.warning
        case .running: AryaColor.accent
        case .queued: AryaColor.inkMuted
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(label.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(width: 72, alignment: .leading)
            Text(value).aryaText(AryaFont.monoSmall, AryaColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

enum PeopleThreadText {
    static func placeholder(_ name: String) -> String { "Message as \(name)…" }

    static func empty(_ name: String) -> String {
        "No messages with \(name) yet. Write as them below to ask, correct, or hand off work."
    }

    /// The intent of an inbound message ("hand off"), or an outbound action's kind ("reply").
    static func tag(_ entry: PeopleThread.Entry) -> String? {
        if entry.inbound {
            return entry.intent.flatMap(MessageIntent.init(rawValue:))?.label.lowercased()
        }
        return entry.action.map(ActionWords.kind)
    }

    /// "2 sent · last 3d ago" for the reports this person received, nil when none.
    static func reports(_ thread: PeopleThread, now: Date) -> String? {
        let sent = thread.entries.filter { $0.action == "report" }
        guard let last = sent.last else { return nil }
        return "\(sent.count) sent · last \(FeatureTime.relative(last.at, now: now))"
    }

    /// "3 in · 1 out · 1 open hand-off".
    /// Messages in and out, reports left out (one source for rows, roster, and inspector).
    static func tally(_ thread: PeopleThread) -> (inbound: Int, outbound: Int) {
        let messages = thread.entries.filter { $0.action != "report" }
        let inbound = messages.filter(\.inbound).count
        return (inbound, messages.count - inbound)
    }

    static func counts(_ thread: PeopleThread) -> String {
        let messages = thread.entries.filter { $0.action != "report" }
        let inbound = messages.filter(\.inbound).count
        var out = "\(inbound) in · \(messages.count - inbound) out"
        if thread.open > 0 {
            out += " · \(thread.open) open hand-off" + (thread.open == 1 ? "" : "s")
        }
        return out
    }
}
