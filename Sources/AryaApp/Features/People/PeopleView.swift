import Arya
import AryaDesign
import SwiftUI

/// The People page: who stewards work with, their role, how to reach them, what they may
/// approve, and how often they have written. It opens on All stewards (everyone once, with the
/// stewards and departments they work with); a steward scope adds the thread, reports, and
/// channels, and folds everyone else under "Not with this steward". Add, edit, and remove
/// propose a charter change that goes live through the gate on Improve.
struct PeopleView: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    let steward: String?
    /// The selected person: their conversation opens under their row.
    let selected: String?
    let selectSteward: (String?) -> Void
    let select: (String) -> Void
    /// Opens a person in a steward's scope (All stewards' Message).
    var open: (String, String) -> Void = { _, _ in }
    @ObservedObject var reports: ReportDigestStore
    let readReport: @Sendable (String) async throws -> ReportDigest
    /// People or Channels.
    var pane: PeoplePane = .people
    var selectPane: (PeoplePane) -> Void = { _ in }
    /// Connection tests, for a relay channel's status.
    var tests: [String: ConnectionTest] = [:]
    /// Opens an approval in Needs you (the detail's Waiting on list).
    var review: (String) -> Void = { _ in }

    /// `"new"`, a person id being edited, or nil.
    @AryaState private var editing: String?
    @AryaState private var draft = PersonDraft()
    @AryaState private var note: String?
    /// The person whose removal waits on confirmation.
    @AryaState private var removing: String?
    /// The "Not with this steward" group is open.
    @AryaState private var othersOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s5) {
                PageTitle(
                    title: "People",
                    subtitle: "Who stewards work with, how they reach them, and what they "
                        + "may approve.")
                if !stewards.isEmpty {
                    HStack(spacing: AryaSpace.s3) {
                        StewardPicker(stewards: stewards, selected: steward) {
                            editing = nil
                            selectSteward($0)
                        }
                        Spacer()
                        if steward != nil {
                            AryaSegmented(
                                PeoplePane.allCases.map { ($0, $0.title) }, selection: pane,
                                choose: selectPane
                            )
                            .accessibilityLabel("Show")
                        }
                    }
                }
                if let note { Text(note).aryaText(AryaFont.caption, AryaColor.inkMuted) }
                if let error = store.writeError {
                    InlineError(error) { store.dismissWriteError() }
                }
                let roster = PeopleRoster(
                    events: store.events, stewards: stewards.map(\.id),
                    conversations: store.conversations)
                if let steward {
                    let people = PeopleDirectory(events: store.events, steward: steward)
                    switch pane {
                    case .people:
                        split {
                            directory(people, steward)
                            others(roster.notWith(steward), directory: people)
                        } detail: {
                            if let person = people.people.first(where: { $0.id == selected })
                                ?? people.people.first
                            {
                                PersonDetailColumn(
                                    store: store, stewards: stewards, person: person,
                                    with: [steward], fixed: steward, review: review)
                            }
                        }
                    case .channels:
                        PeopleChannelsView(store: store, steward: steward, tests: tests)
                    case .reports:
                        PeopleReportSection(
                            store: store, reports: reports, directory: people, read: readReport,
                            propose: propose)
                        PeopleReportHistoryView(store: store, directory: people)
                    }
                } else {
                    split {
                        everyone(roster)
                    } detail: {
                        if let person = roster.people.first(where: { $0.id == selected })
                            ?? roster.people.first
                        {
                            PersonDetailColumn(
                                store: store, stewards: stewards, person: person.first,
                                with: person.stewards, fixed: nil, review: review
                            )
                            .id(person.id)
                        }
                    }
                }
            }
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("People")
        .confirmationDialog(
            removeTitle,
            isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Propose removal", role: .destructive) {
                if let steward, let id = removing {
                    propose(
                        PeopleDirectory(events: store.events, steward: steward).removeProposal(id))
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(
                "The steward stops messaging them and drops their approvals once the change "
                    + "passes the gate."
            )
        }
    }

    /// The list on the left and the selected person on the right, so the page has no blank
    /// canvas below a short list.
    private func split<List: View, Detail: View>(
        @ViewBuilder _ list: () -> List, @ViewBuilder detail: () -> Detail
    ) -> some View {
        HStack(alignment: .top, spacing: AryaSpace.s5) {
            VStack(alignment: .leading, spacing: 0) { list() }
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 440, alignment: .leading)
            AryaHairline(.vertical)
            detail().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func directory(_ directory: PeopleDirectory, _ steward: String) -> some View {
        if directory.people.isEmpty, editing == nil {
            EmptyState(
                "No people yet.", guidance: "Add the people this steward answers to and asks.")
        }
        ForEach(directory.people) { person in
            if editing == person.id {
                form(directory, editing: person.id)
            } else {
                row(person, directory: directory)
            }
            AryaHairline()
        }
        if editing == "new" {
            form(directory, editing: nil)
        } else if directory.live != nil {
            Button("Add person") {
                draft = PersonDraft()
                editing = "new"
            }
            .buttonStyle(.aryaSecondary)
        }
    }

    /// All stewards: everyone once, with the stewards and departments they work with.
    @ViewBuilder
    private func everyone(_ roster: PeopleRoster) -> some View {
        if roster.people.isEmpty {
            EmptyState(
                "No people yet.", guidance: "Pick a steward and add the people it works with.")
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(roster.people) { person in
                rosterRow(person)
                AryaHairline()
            }
        }
    }

    private var lastContact: [String: Date] { PeopleDetailText.lastContact(store.events) }

    private var latest: [String: (text: String, inbound: Bool)] {
        PeopleDetailText.lastMessage(store.events)
    }

    private func rosterRow(_ person: PeopleRoster.Person) -> some View {
        let names = person.stewards.map { id in stewards.first { $0.id == id }?.name ?? id }
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .center, spacing: AryaSpace.s3) {
                Text(person.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                if let role = person.role {
                    Text(role).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
                Spacer()
                let taught = PeopleLearned(events: store.events, person: person.id).live.count
                if taught > 0 {
                    Text("taught \(taught)").aryaText(AryaFont.monoSmall, AryaColor.positive)
                        .help("Notes stewards keep from \(person.name)'s corrections")
                }
                Text("\(person.inbound) in · \(person.outbound) out")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
                Text(
                    lastContact[person.id].map {
                        "last contact " + FeatureTime.relative($0, now: store.now)
                    } ?? "no contact yet"
                )
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                Text(RosterText.names(names)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            .lineLimit(1)
            // The newest message either way, and the newest thing Arya learned from them.
            if let last = latest[person.id] {
                Text((last.inbound ? person.name : "Steward") + ": " + last.text)
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let note = PeopleLearned(events: store.events, person: person.id).live.first,
                note.text != latest[person.id]?.text
            {
                Text("learned: " + note.text)
                    .aryaText(AryaFont.caption, AryaColor.positive)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AryaSpace.s2)
        .padding(.horizontal, AryaSpace.s2)
        .background(
            selected == person.id ? AryaColor.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(person.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected == person.id ? .isSelected : [])
    }

    /// "Not with this steward (3)": people other stewards work with, each with a quiet
    /// Add to steward… that opens the add form filled in.
    @ViewBuilder
    private func others(_ people: [PeopleRoster.Person], directory: PeopleDirectory)
        -> some View
    {
        if !people.isEmpty, directory.live != nil {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(AryaMotion.quick) { othersOpen.toggle() }
                } label: {
                    HStack(spacing: AryaSpace.s1) {
                        DisclosureChevron(isExpanded: othersOpen)
                        Text("NOT WITH THIS STEWARD (\(people.count))")
                            .aryaText(AryaFont.label, AryaColor.inkFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not with this steward, \(people.count)")
                .padding(.vertical, AryaSpace.s2)
                if othersOpen {
                    ForEach(people) { person in
                        HStack(spacing: AryaSpace.s3) {
                            Text(person.name).aryaText(AryaFont.body, AryaColor.ink)
                            if let role = person.role {
                                Text(role).aryaText(AryaFont.caption, AryaColor.inkMuted)
                            }
                            Spacer()
                            Button("Add to steward…") {
                                var filled = PersonDraft(person.first)
                                // A relay this steward lacks would fail the gate; start local.
                                if !filled.via.isEmpty, !directory.relays.contains(filled.via) {
                                    filled.via = ""
                                    filled.channel = "inbox"
                                }
                                draft = filled
                                editing = "new"
                            }
                            .buttonStyle(.aryaTertiary)
                        }
                        .frame(minHeight: AryaSize.rowHeight)
                        AryaHairline()
                    }
                }
            }
        }
    }

    private func row(_ person: PeopleDirectory.Person, directory: PeopleDirectory) -> some View {
        let thread = PeopleThread(
            events: store.events, steward: directory.steward, person: person.id,
            conversation: store.conversations["\(directory.steward)/\(person.id)"])
        let last = thread.entries.last
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .center, spacing: AryaSpace.s3) {
                Text(person.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                if let role = person.role {
                    Text(role).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
                Spacer()
                if thread.open > 0 {
                    Text(thread.open == 1 ? "1 open hand-off" : "\(thread.open) open hand-offs")
                        .aryaText(AryaFont.monoSmall, AryaColor.accent)
                }
                if let last {
                    Text(FeatureTime.relative(last.at, now: store.now))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                MoreMenu(label: "More for \(person.name)") {
                    Button("Edit…") {
                        draft = PersonDraft(person)
                        editing = person.id
                    }
                    Button("Remove…", role: .destructive) { removing = person.id }
                }
            }
            // Reach and approvals are in the detail header beside the list.
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
                Text(PeopleThreadText.counts(thread)).aryaText(
                    AryaFont.monoSmall, AryaColor.inkFaint)
                if let reports = PeopleThreadText.reports(thread, now: store.now) {
                    Text("reports " + reports).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, AryaSpace.s2)
        .padding(.horizontal, AryaSpace.s2)
        .background(
            selected == person.id ? AryaColor.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(person.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected == person.id ? .isSelected : [])
    }

    private func form(_ directory: PeopleDirectory, editing id: String?) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            field("Name") { CharterTextField(placeholder: "Alex Kim", text: $draft.name) }
            field("Role") { CharterTextField(placeholder: "support lead", text: $draft.role) }
            field("Through") {
                AryaSegmented(
                    [("", "Local inbox")] + directory.relays.map { ($0, $0) },
                    selection: draft.via
                ) { draft.via = $0 }
            }
            if !draft.via.isEmpty {
                field("Address") {
                    CharterTextField(
                        placeholder: "their address on \(draft.via)", text: $draft.channel,
                        mono: true)
                }
            }
            field("Approves") {
                CharterTextField(
                    placeholder: directory.actionKinds.isEmpty
                        ? "refund, reply, or *" : directory.actionKinds.joined(separator: ", "),
                    text: $draft.approves, mono: true)
            }
            ForEach(draft.issues, id: \.self) {
                Text($0).aryaText(AryaFont.caption, AryaColor.warning)
            }
            HStack(spacing: AryaSpace.s3) {
                Button("Propose") {
                    propose(directory.saveProposal(draft, editing: id))
                    editing = nil
                }
                .buttonStyle(.aryaPrimary)
                .disabled(!draft.issues.isEmpty)
                Button("Cancel") { editing = nil }.buttonStyle(.aryaTertiary)
            }
        }
        .padding(.vertical, AryaSpace.s2)
    }

    private var removeTitle: String {
        guard let steward, let id = removing else { return "Remove?" }
        let name =
            PeopleDirectory(events: store.events, steward: steward).people.first { $0.id == id }?
            .name ?? PeopleDirectory.displayName(id)
        return "Remove \(name)?"
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(title.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func propose(_ proposal: CharterProposal?) {
        guard let proposal else { return }
        Task {
            if await store.perform(.proposeCharter(proposal)) {
                note =
                    "Proposed “\(proposal.title)”. It goes live once it passes the gate "
                    + "on Improve."
            }
        }
    }
}

/// Who may approve an approval's action, under the approval card; nothing when no one is named.
struct ApproversLine: View {
    let events: [FeatureEvent]
    let steward: String?
    let kind: String

    var body: some View {
        if let steward {
            let directory = PeopleDirectory(events: events, steward: steward)
            if let people = directory.approvers(of: kind), !people.isEmpty {
                Text(ApproversText.line(people.map(directory.approverName)))
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
            }
        }
    }
}

enum ApproversText {
    /// "May approve: You, Sam (support lead)".
    static func line(_ names: [String]) -> String {
        "May approve: " + names.joined(separator: ", ")
    }
}

/// What the People page shows: the directory with threads, or the channels people use.
enum PeoplePane: String, CaseIterable, Hashable, Sendable {
    case people, channels, reports

    var title: String {
        switch self {
        case .people: "People"
        case .channels: "Channels"
        case .reports: "Reports"
        }
    }
}

/// A 24 pt ellipsis that opens a menu of less-used actions (Edit, Remove), so a row keeps one
/// visible button.
struct MoreMenu<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .aryaText(AryaFont.bodyStrong, AryaColor.inkMuted)
                .frame(width: AryaSize.buttonHeight, height: AryaSize.buttonHeight)
                .contentShape(Rectangle())
        }
        .aryaMenuButton()
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}
