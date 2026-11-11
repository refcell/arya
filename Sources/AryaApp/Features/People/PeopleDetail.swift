import Arya
import AryaDesign
import SwiftUI

/// Approvals and questions waiting on a person: questions addressed to them, and held actions
/// of a kind they may approve for a steward they work with.
enum PersonWaiting {
    struct Item: Identifiable, Hashable, Sendable {
        var id: String
        var steward: String?
        var text: String
        var at: Date
        var question: Bool
    }

    static func build(
        events: [FeatureEvent], person: String, approves: Set<String>, stewards: Set<String>
    ) -> [Item] {
        var open: [String: Item] = [:]
        var order: [String] = []
        for event in events {
            switch event.type {
            case "approval.requested":
                let payload = event.payload
                guard let id = payload["approval"]?.string else { continue }
                let action = payload["action"]
                let kind = action?["kind"]?.string ?? ""
                let question = payload["kind"]?.string == "question"
                let mine =
                    payload["to"]?.string == person
                    || (approves.contains(kind) && stewards.contains(event.steward ?? ""))
                guard mine else { continue }
                let text =
                    question
                    ? (payload["question"]?.string ?? action?["params"]?["text"]?.string ?? kind)
                    : [ActionWords.kind(kind), action?["target"]?.string ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                open[id] = Item(
                    id: id, steward: event.steward, text: text, at: event.at, question: question)
                order.append(id)
            case "approval.granted", "approval.denied":
                if let id = event.payload["approval"]?.string { open[id] = nil }
            default: continue
            }
        }
        return order.reversed().compactMap { open[$0] }
    }
}

/// The right half of People: the selected person's thread with one steward, what stewards
/// remember about them and learned from them, and what waits on them.
struct PersonDetailColumn: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    let person: PeopleDirectory.Person
    /// The stewards they work with, most-talked first; the thread opens with the first.
    let with: [String]
    /// A steward page scope pins the thread to that steward.
    let fixed: String?
    var review: (String) -> Void = { _ in }

    @AryaState private var chosen: String?

    var body: some View {
        let steward = fixed ?? chosen.flatMap { with.contains($0) ? $0 : nil } ?? with.first
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            header(steward)
            activity
            if with.count > 1 { threads(steward) }
            if let steward {
                PersonThreadView(
                    store: store, steward: steward, person: person, stewardName: name(steward))
            }
            HStack(alignment: .top, spacing: AryaSpace.s5) {
                remembers.frame(maxWidth: .infinity, alignment: .leading)
                learned.frame(maxWidth: .infinity, alignment: .leading)
            }
            waiting
        }
        .task(id: person.id) { await store.loadPersonNotes(person.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(person.name)
    }

    private func header(_ steward: String?) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(person.name).aryaText(AryaFont.heading, AryaColor.ink)
                if let role = person.role {
                    Text(role).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
                Spacer()
                if fixed == nil, with.count > 1, let steward {
                    Menu {
                        ForEach(with, id: \.self) { id in
                            Button(name(id)) { chosen = id }
                        }
                    } label: {
                        Text("with \(name(steward)) ▾").aryaText(AryaFont.caption, AryaColor.ink)
                    }
                    .aryaMenuButton()
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Show their thread with another steward")
                }
            }
            HStack(spacing: AryaSpace.s4) {
                Text(person.reach).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                if let approves = PeopleText.approves(person.approves) {
                    Text(approves).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
                Text("works with " + RosterText.names(with.map(name)))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            .lineLimit(1)
        }
    }

    /// Messages in and out per day for two weeks, today last.
    private var activity: some View {
        let days = PeopleDetailText.daily(store.events, person: person.id, now: store.now)
        let peak = max(days.map { $0.inbound + $0.outbound }.max() ?? 0, 1)
        let barHeight: CGFloat = 32
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack {
                Text("MESSAGES · 14 DAYS").aryaText(AryaFont.label, AryaColor.inkFaint)
                Spacer()
                Text(
                    "\(Int(days.map(\.inbound).reduce(0, +))) in · "
                        + "\(Int(days.map(\.outbound).reduce(0, +))) out"
                )
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: AryaRadius.small)
                            .fill(AryaColor.inkMuted)
                            .frame(height: barHeight * day.outbound / peak)
                        RoundedRectangle(cornerRadius: AryaRadius.small)
                            .fill(AryaColor.positive)
                            .frame(height: max(2, barHeight * day.inbound / peak))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: barHeight + 2, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Messages per day with \(person.name) for two weeks")
    }

    /// One line per steward they work with: counts and the newest message; picks the thread.
    private func threads(_ current: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THREADS").aryaText(AryaFont.label, AryaColor.inkFaint)
                .padding(.bottom, AryaSpace.s1)
            ForEach(with, id: \.self) { id in
                let thread = PeopleThread(
                    events: store.events, steward: id, person: person.id,
                    conversation: store.conversations["\(id)/\(person.id)"])
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                        Text(name(id)).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                            .lineLimit(1)
                        Spacer(minLength: AryaSpace.s2)
                        Text(PeopleThreadText.counts(thread))
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
                    }
                    Text(thread.entries.last?.text ?? "No messages yet.")
                        .aryaText(AryaFont.caption, AryaColor.inkMuted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AryaSpace.s2)
                .padding(.vertical, AryaSpace.s1)
                .frame(minHeight: AryaSize.rowHeight)
                .background(
                    current == id ? AryaColor.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: AryaRadius.small)
                )
                .contentShape(Rectangle())
                .onTapGesture { chosen = id }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(current == id ? .isSelected : [])
            }
        }
    }

    /// What stewards remember about them (decision 0061), with where each note came from.
    private var remembers: some View {
        let notes = store.personNotes[person.id] ?? []
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            label("REMEMBERS ABOUT \(person.name.uppercased())", count: notes.count)
            if notes.isEmpty {
                Text("Nothing yet. What they prefer reaches only runs that act for them.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(notes.prefix(4)) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(3)
                    Text(
                        PeopleDetailText.provenance(
                            note, people: [person.id: person.name],
                            stewards: StewardNames.build(events: store.events))
                    )
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var learned: some View {
        let items = PeopleLearned(events: store.events, person: person.id).live
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            label("LEARNED FROM \(person.name.uppercased())", count: items.count)
            if items.isEmpty {
                Text("Nothing yet. Their corrections become notes every run reads.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(items.prefix(4)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(3)
                    Text(
                        [
                            item.source, item.steward.map(name),
                            FeatureTime.relative(item.at, now: store.now),
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var waiting: some View {
        let items = PersonWaiting.build(
            events: store.events, person: person.id, approves: Set(person.approves),
            stewards: Set(with))
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            label("WAITING ON \(person.name.uppercased())", count: items.count)
            if items.isEmpty {
                Text("Nothing waits on them.").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(items.prefix(5)) { item in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(item.question ? "asks" : "approve")
                        .aryaText(AryaFont.monoSmall, AryaColor.warning)
                        .frame(minWidth: 52, alignment: .leading)
                    Text(item.text).aryaText(AryaFont.caption, AryaColor.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: AryaSpace.s2)
                    Text(item.steward.map(name) ?? "")
                        .aryaText(AryaFont.caption, AryaColor.inkFaint).lineLimit(1)
                    Text(FeatureTime.relative(item.at, now: store.now))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    Button("Review") { review(item.id) }
                        .buttonStyle(.aryaTertiary)
                        .help("Open it in Needs you")
                }
                .frame(minHeight: AryaSize.rowHeight)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func label(_ text: String, count: Int) -> some View {
        HStack(spacing: AryaSpace.s2) {
            Text(text).aryaText(AryaFont.label, AryaColor.inkFaint)
            if count > 0 {
                Text("\(count)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
        }
    }

    private func name(_ id: String) -> String { stewards.first { $0.id == id }?.name ?? id }
}

enum PeopleDetailText {
    /// "from Lee · Support inbox triage · run", "shared · noted by you".
    static func provenance(
        _ note: FeaturePersonNote, people: [String: String], stewards: [String: String]
    ) -> String {
        // Authors arrive as "human:sam", "person:sam" or "sam"; "local" is you.
        let bare = String(note.author.split(separator: ":").last ?? "")
        let author =
            people[note.author] ?? people["person:" + bare]
            ?? PeopleDirectory.displayName(note.author)
        let source =
            note.tags.contains("correction")
            ? "\(author)'s correction"
            : note.run != nil
                ? "learned in a run" : author == "you" ? "noted by you" : "told by \(author)"
        let scope =
            note.steward == "shared" || note.steward == "st_shared"
            ? "shared by every steward" : stewards[note.steward] ?? note.steward
        return "\(source) · \(scope)"
    }

    /// Messages from the person (in) and replies to them (out) per day, 14 days, today last.
    static func daily(_ events: [FeatureEvent], person: String, now: Date, days: Int = 14)
        -> [(inbound: Double, outbound: Double)]
    {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        var result = [(inbound: Double, outbound: Double)](repeating: (0, 0), count: days)
        for event in events {
            let inbound = event.type == "inbox.message" && event.payload["from"]?.string == person
            let outbound =
                event.type == "action.proposed"
                && event.payload["action"]?["binding"]?.string == person
            guard inbound || outbound else { continue }
            let back =
                calendar.dateComponents([.day], from: calendar.startOfDay(for: event.at), to: today)
                .day ?? days
            guard back >= 0, back < days else { continue }
            if inbound {
                result[days - 1 - back].inbound += 1
            } else {
                result[days - 1 - back].outbound += 1
            }
        }
        return result
    }

    /// The newest message from or to each person, by person id: their text, or the reply's.
    static func lastMessage(_ events: [FeatureEvent]) -> [String: (text: String, inbound: Bool)] {
        var last: [String: (text: String, inbound: Bool)] = [:]
        for event in events {
            switch event.type {
            case "inbox.message":
                if let who = event.payload["from"]?.string, who.hasPrefix("person:"),
                    let text = event.payload["text"]?.string ?? event.payload["body"]?.string
                {
                    last[who] = (text, true)
                }
            case "action.proposed":
                let action = event.payload["action"]
                if let who = action?["binding"]?.string, who.hasPrefix("person:"),
                    let text = action?["params"]?["text"]?.string
                {
                    last[who] = (text, false)
                }
            default: continue
            }
        }
        return last
    }

    /// When a person last messaged a steward or a steward answered them, by person id.
    static func lastContact(_ events: [FeatureEvent]) -> [String: Date] {
        var last: [String: Date] = [:]
        for event in events {
            let who: String?
            switch event.type {
            case "inbox.message": who = event.payload["from"]?.string
            case "action.proposed": who = event.payload["action"]?["binding"]?.string
            default: who = nil
            }
            if let who, who.hasPrefix("person:") { last[who] = event.at }
        }
        return last
    }
}
