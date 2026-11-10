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
    let selectSteward: (String) -> Void

    /// `"new"`, a person id being edited, or nil.
    @AryaState private var editing: String?
    @AryaState private var draft = PersonDraft()
    @AryaState private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s5) {
                PageTitle(
                    title: "People",
                    subtitle: "Who a steward works with, how it reaches them, and what they "
                        + "may approve.")
                if stewards.count > 1, let steward {
                    ChoiceRow(stewards.map { ($0.id, $0.name) }, selection: steward) {
                        editing = nil
                        selectSteward($0)
                    }
                }
                if let note { Text(note).aryaText(AryaFont.caption, AryaColor.inkMuted) }
                if let error = store.writeError {
                    InlineError(error) { store.dismissWriteError() }
                }
                if let steward {
                    directory(PeopleDirectory(events: store.events, steward: steward))
                }
            }
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("People")
    }

    @ViewBuilder
    private func directory(_ directory: PeopleDirectory) -> some View {
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

    private func row(_ person: PeopleDirectory.Person, directory: PeopleDirectory) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text(person.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                if let role = person.role {
                    Text(role).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
                Text(person.id).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                Spacer()
                Button("Edit") {
                    draft = PersonDraft(person)
                    editing = person.id
                }
                .buttonStyle(.aryaTertiary)
                Button("Remove") { propose(directory.removeProposal(person.id)) }
                    .buttonStyle(.aryaQuiet)
            }
            field("Reach") { Text(person.reach).aryaText(AryaFont.monoSmall, AryaColor.ink) }
            field("Approves") {
                if person.approves.isEmpty {
                    Text("Nothing").aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
                ForEach(person.approves, id: \.self) {
                    Chip($0 == "*" ? "any action" : $0, textColor: AryaColor.ink)
                }
            }
            field("Messages") {
                Text(messages(person)).aryaText(AryaFont.caption, AryaColor.inkMuted)
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
                ChoiceRow(
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

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(title.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func messages(_ person: PeopleDirectory.Person) -> String {
        guard person.messages > 0 else { return "None yet" }
        let count = person.messages == 1 ? "1 message" : "\(person.messages) messages"
        return person.lastMessage.map { "\(count) · last: \($0)" } ?? count
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
