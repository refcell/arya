import AryaDesign
import SwiftUI

/// A person's conversation with the steward on the People page: their messages and the
/// steward's replies, oldest first, then a composer that writes as that person ("Message as
/// Sam") with Ask, Correct, or Hand off.
struct PersonThreadView: View {
    @ObservedObject var store: FeatureStore
    let steward: String
    let person: PeopleDirectory.Person

    @AryaState private var text = ""
    @AryaState private var intent = MessageIntent.ask

    var body: some View {
        let thread = PeopleThread(events: store.events, steward: steward, person: person.id)
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            if thread.entries.isEmpty {
                Text(PeopleThreadText.empty(person.name))
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(thread.entries) { entry(person, $0) }
            composer
        }
        .padding(.leading, AryaSpace.s4)
        .overlay(alignment: .leading) {
            Rectangle().fill(AryaColor.rule).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation with \(person.name)")
    }

    private func entry(_ person: PeopleDirectory.Person, _ entry: PeopleThread.Entry)
        -> some View
    {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(entry.inbound ? person.name : "Steward")
                    .aryaText(AryaFont.bodyStrong, entry.inbound ? AryaColor.ink : AryaColor.accent)
                if let tag = PeopleThreadText.tag(entry) {
                    Chip(tag, textColor: AryaColor.inkMuted)
                }
                if let run = entry.run {
                    Text(run).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
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
            ChoiceRow(
                MessageIntent.allCases.map { ($0, $0.label) }, selection: intent
            ) { intent = $0 }
            TextField(PeopleThreadText.placeholder(person.name), text: $text)
                .textFieldStyle(.plain)
                .aryaText(AryaFont.body, AryaColor.ink)
                .padding(.horizontal, AryaSpace.s2)
                .padding(.vertical, AryaSpace.s1)
                .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(.aryaSecondary)
                .disabled(trimmed.isEmpty)
        }
        .padding(.top, AryaSpace.s1)
    }

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

    var body: some View {
        let directory = PeopleDirectory(events: store.events, steward: steward)
        if let found = directory.people.first(where: { $0.id == person }) {
            let thread = PeopleThread(events: store.events, steward: steward, person: person)
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text(found.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                    Text(found.id).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                fact("Role", found.role ?? "none")
                fact("Reach", found.reach)
                fact(
                    "Approves",
                    found.approves.isEmpty
                        ? "nothing"
                        : found.approves.map { $0 == "*" ? "any action" : $0 }
                            .joined(separator: ", "))
                fact("Messages", PeopleThreadText.counts(thread))
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("HANDED OFF").aryaText(AryaFont.label, AryaColor.inkFaint)
                    if thread.tasks.isEmpty {
                        Text("Nothing yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                    ForEach(thread.tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            Chip(task.status.label, textColor: Self.color(task.status))
                            Text(task.text).aryaText(AryaFont.caption, AryaColor.ink)
                                .lineLimit(2)
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
        return entry.action
    }

    /// "3 in · 1 out · 1 open hand-off".
    static func counts(_ thread: PeopleThread) -> String {
        let inbound = thread.entries.filter(\.inbound).count
        var out = "\(inbound) in · \(thread.entries.count - inbound) out"
        if thread.open > 0 {
            out += " · \(thread.open) open hand-off" + (thread.open == 1 ? "" : "s")
        }
        return out
    }
}
