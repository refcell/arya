import Arya
import AryaDesign
import SwiftUI

/// The People page: who a steward works with, their role, how to reach them, what they may
/// approve, and how often they have written. Add, edit, and remove propose a charter change
/// that goes live through the gate on Improve.
struct PeopleView: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    let steward: String?
    /// The selected person: their conversation opens under their row.
    let selected: String?
    let selectSteward: (String) -> Void
    let select: (String) -> Void
    @ObservedObject var reports: ReportDigestStore
    let readReport: @Sendable (String) async throws -> ReportDigest
    /// People or Channels.
    var pane: PeoplePane = .people
    var selectPane: (PeoplePane) -> Void = { _ in }
    /// Connection tests, for a relay channel's status.
    var tests: [String: ConnectionTest] = [:]

    /// `"new"`, a person id being edited, or nil.
    @AryaState private var editing: String?
    @AryaState private var draft = PersonDraft()
    @AryaState private var note: String?
    /// The person whose removal waits on confirmation.
    @AryaState private var removing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s5) {
                PageTitle(
                    title: "People",
                    subtitle: "Who a steward works with, how it reaches them, and what they "
                        + "may approve.")
                if let steward {
                    HStack(spacing: AryaSpace.s3) {
                        StewardPicker(stewards: stewards, selected: steward) {
                            editing = nil
                            selectSteward($0)
                        }
                        Spacer()
                        AryaSegmented(
                            PeoplePane.allCases.map { ($0, $0.title) }, selection: pane,
                            choose: selectPane
                        )
                        .accessibilityLabel("Show")
                    }
                }
                if let note { Text(note).aryaText(AryaFont.caption, AryaColor.inkMuted) }
                if let error = store.writeError {
                    InlineError(error) { store.dismissWriteError() }
                }
                if let steward {
                    let people = PeopleDirectory(events: store.events, steward: steward)
                    switch pane {
                    case .people:
                        directory(people, steward)
                        PeopleReportSection(
                            store: store, reports: reports, directory: people, read: readReport,
                            propose: propose)
                    case .channels:
                        PeopleChannelsView(store: store, steward: steward, tests: tests)
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
                if selected == person.id {
                    PersonThreadView(
                        store: store, steward: steward, person: person,
                        stewardName: directory.live?.charter["name"]?.string ?? steward
                    )
                    .padding(.bottom, AryaSpace.s2)
                }
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
                if selected != person.id {
                    Button("Message") { select(person.id) }
                        .buttonStyle(.aryaSecondary)
                        .help("Open the conversation and write as \(person.name)")
                }
                MoreMenu(label: "More for \(person.name)") {
                    Button("Edit…") {
                        draft = PersonDraft(person)
                        editing = person.id
                    }
                    Button("Remove…", role: .destructive) { removing = person.id }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
                Text(person.reach).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                Text(
                    person.approves.isEmpty
                        ? "approves nothing"
                        : "approves "
                            + person.approves.map {
                                $0 == "*" ? "any action" : ActionWords.kind($0)
                            }
                            .joined(
                                separator: ", ")
                )
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                Text(PeopleThreadText.counts(thread)).aryaText(
                    AryaFont.monoSmall, AryaColor.inkFaint)
                if let reports = PeopleThreadText.reports(thread, now: store.now) {
                    Text("reports " + reports).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            .lineLimit(1)
            if selected != person.id, let last {
                Text((last.inbound ? person.name : "Steward") + ": " + last.text)
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, AryaSpace.s2)
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
    case people, channels

    var title: String {
        switch self {
        case .people: "People"
        case .channels: "Channels"
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
