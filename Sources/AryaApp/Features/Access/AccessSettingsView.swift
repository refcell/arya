import Arya
import AryaDesign
import SwiftUI

/// Column widths of the Access lists, on the 4 pt grid.
enum AccessLayout {
    static let subject = AryaSpace.s7 * 4 + AryaSpace.s3
    static let check = AryaSpace.s3
    /// The Teams and Refused column beside Grants on the window page.
    static let side = AryaSpace.s7 * 10
}

/// The tabs of Settings ▸ Access.
enum AccessTab: Hashable {
    case grants, teams, refused
}

/// Settings ▸ Access: who may use, approve, or see each steward, connection, and tool; the
/// teams grants can name; and what was refused for want of a grant. One primary action
/// (Grant…); revoke and undo are quiet.
struct AccessSettingsView: View {
    /// The Settings window's content size for this tab.
    static let windowSize = CGSize(width: 640, height: 560)

    let source: (any AccessSettingsSource)?
    /// In the main window's stream, between the sidebar and the inspector, rather than the
    /// Settings window.
    var page = false
    var model = AccessModel.shared
    @AryaState var tab: AccessTab = .grants
    @AryaState var draft: GrantDraft?
    @AryaState var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let problem = model.problem {
                InlineError(problem) { model.problem = nil }.padding(.bottom, AryaSpace.s2)
            }
            if let draft = Binding($draft), let overview = model.overview {
                GrantForm(
                    overview: overview, draft: draft,
                    grant: { chosen in
                        Task {
                            guard let source else { return }
                            if await model.grant(chosen, from: source) { self.draft = nil }
                        }
                    },
                    cancel: { self.draft = nil }
                )
                .padding(.bottom, AryaSpace.s3)
            }
            if page, let overview = model.overview {
                columns(overview)
            } else {
                tabbed
            }
        }
        .padding(.horizontal, page ? AryaSize.pagePadding : AryaSpace.s4)
        .padding(.top, page ? AryaSize.titleBarInset : AryaSpace.s4)
        .padding(.bottom, AryaSpace.s4)
        .frame(
            minWidth: page ? nil : Self.windowSize.width,
            maxWidth: page ? .infinity : nil,
            minHeight: page ? nil : Self.windowSize.height,
            maxHeight: page ? .infinity : nil,
            alignment: .topLeading
        )
        .background(AryaColor.canvas)
        .task {
            if let source { await model.load(from: source) }
        }
    }

    /// Settings window: one list at a time under text tabs.
    @ViewBuilder private var tabbed: some View {
        TextTabBar(
            tabs: [
                TextTab(
                    id: AccessTab.grants, title: "Grants",
                    count: model.overview?.grants.count ?? 0),
                TextTab(
                    id: AccessTab.teams, title: "Teams", count: model.overview?.teams.count ?? 0
                ),
                TextTab(
                    id: AccessTab.refused, title: "Refused",
                    count: model.overview?.refusals.count ?? 0),
            ], selection: $tab)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let overview = model.overview {
                    switch tab {
                    case .grants: grants(overview)
                    case .teams: TeamsList(overview: overview, source: source, model: model)
                    case .refused: refusals(overview)
                    }
                } else {
                    Text("Loading access…").aryaText(AryaFont.body, AryaColor.inkMuted)
                        .padding(.top, AryaSpace.s3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The window page: Grants beside Teams and Refused, so every list shows at once.
    private func columns(_ overview: AccessOverview) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: AryaSpace.s6) {
                VStack(alignment: .leading, spacing: 0) {
                    column("Grants", overview.grants.count)
                    grants(overview)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    TeamsList(overview: overview, source: source, model: model, titled: true)
                    column("Refused", overview.refusals.count).padding(.top, AryaSpace.s4)
                    refusals(overview)
                    column("People", overview.people.count).padding(.top, AryaSpace.s4)
                    people(overview)
                }
                .frame(width: AccessLayout.side, alignment: .leading)
            }
            .padding(.top, AryaSpace.s2)
        }
    }

    /// Each person and what they may do through their grants and teams.
    private func people(_ overview: AccessOverview) -> some View {
        ForEach(overview.people, id: \.self) { person in
            TableRowFrame {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: AryaSpace.s2) {
                        Text(AccessText.who(person)).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                        Text(AccessText.teams(of: person, in: overview).joined(separator: ", "))
                            .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                    Text(AccessText.effective(person, in: overview))
                        .aryaText(AryaFont.caption, AryaColor.inkMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, AryaSpace.s1)
                Spacer(minLength: 0)
            }
        }
    }

    private func column(_ title: String, _ count: Int) -> some View {
        HStack(spacing: AryaSpace.s1) {
            Text(title.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
            Text("\(count)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        }
        .padding(.vertical, AryaSpace.s1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text("Access").aryaText(AryaFont.title, AryaColor.ink)
                Spacer()
                Button("Grant…") { draft = GrantDraft() }
                    .buttonStyle(.aryaPrimary)
                    .disabled(source == nil || model.overview == nil || draft != nil)
                    .accessibilityLabel("Grant access")
            }
            if let overview = model.overview {
                Text(AccessText.status(overview))
                    .aryaText(
                        AryaFont.caption, overview.enforced ? AryaColor.inkMuted : AryaColor.warning
                    )
                if let change = overview.lastChange {
                    HStack(spacing: AryaSpace.s2) {
                        Text(AccessText.change(change, in: overview))
                            .aryaText(AryaFont.caption, AryaColor.inkMuted)
                            .lineLimit(1)
                        Text(AccessText.byline(change.by, change.at, now: now, lead: "· "))
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        if change.undoable {
                            Button("Undo") {
                                Task { if let source { await model.undo(from: source) } }
                            }
                            .buttonStyle(.aryaTertiary)
                            .accessibilityLabel("Undo: \(AccessText.change(change, in: overview))")
                        }
                    }
                }
            }
        }
        .padding(.bottom, AryaSpace.s3)
    }

    /// Grants grouped by what they cover, broadest first.
    @ViewBuilder
    private func grants(_ overview: AccessOverview) -> some View {
        if overview.grants.isEmpty {
            EmptyState(
                "No grants yet.",
                guidance: "Grant use on a connection or tool to let a person or team act through"
                    + " it; until the first grant, nothing is enforced."
            )
            .padding(.top, AryaSpace.s3)
        } else {
            let order = overview.resources.map(\.id)
            let groups = Dictionary(grouping: overview.grants, by: \.resource)
                .sorted {
                    (order.firstIndex(of: $0.key) ?? .max, $0.key)
                        < (order.firstIndex(of: $1.key) ?? .max, $1.key)
                }
            ForEach(groups, id: \.key) { resource, grants in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s1) {
                        Text(AccessText.title(resource, in: overview.resources))
                            .aryaText(AryaFont.bodyStrong, AryaColor.ink)
                        if let kind = AccessText.kind(resource) {
                            Text(kind).aryaText(AryaFont.caption, AryaColor.inkFaint)
                        }
                    }
                    .padding(.top, AryaSpace.s3)
                    .padding(.bottom, AryaSpace.s1)
                    ForEach(
                        grants.sorted { ($0.level, $0.subject) < ($1.level, $1.subject) }, id: \.seq
                    ) {
                        grant in
                        TableRowFrame {
                            Text(AccessText.subject(grant.subject, teams: overview.teams))
                                .aryaText(AryaFont.body, AryaColor.ink)
                                .frame(width: AccessLayout.subject, alignment: .leading)
                            TagPill(grant.level)
                            Spacer(minLength: AryaSpace.s2)
                            Text(AccessText.byline(grant.by, grant.at, now: now))
                                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                            Button("Revoke") {
                                Task { if let source { await model.revoke(grant, from: source) } }
                            }
                            .buttonStyle(.aryaTertiary)
                            .padding(.leading, AryaSpace.s2)
                            .accessibilityLabel(
                                "Revoke: "
                                    + AccessText.grant(
                                        grant, teams: overview.teams,
                                        resources: overview.resources))
                        }
                    }
                }
            }
        }
    }

    /// Recent refusals, newest first.
    @ViewBuilder
    private func refusals(_ overview: AccessOverview) -> some View {
        if overview.refusals.isEmpty {
            EmptyState(
                "Nothing refused.",
                guidance: "When a steward is asked to act for someone without a grant, it is"
                    + " listed here with the reason."
            )
            .padding(.top, AryaSpace.s3)
        } else {
            ForEach(overview.refusals, id: \.seq) { refusal in
                TableRowFrame {
                    Text(AryaTime.label(refusal.at, now: now))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        .frame(width: 44, alignment: .leading)
                    Text("✕").aryaText(AryaFont.mono, AryaColor.negative)
                        .accessibilityLabel("Refused")
                    Text(AccessText.refusal(refusal, in: overview))
                        .aryaText(AryaFont.body, AryaColor.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, AryaSpace.s2)
                        .padding(.vertical, AryaSpace.s1)
                    Spacer(minLength: 0)
                }
                .help(HumanText.sentence(refusal.reason))
            }
        }
    }
}

/// The inline Grant… form: who, what level, on what.
struct GrantForm: View {
    let overview: AccessOverview
    @Binding var draft: GrantDraft
    var grant: (GrantDraft) -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("GRANT").aryaText(AryaFont.label, AryaColor.inkFaint)
            HStack(alignment: .top, spacing: AryaSpace.s4) {
                OptionColumn(
                    title: "Who",
                    options: overview.teams.map {
                        ($0.id, AccessText.subject($0.id, teams: overview.teams))
                    }
                        + overview.people.map { ($0, AccessText.subject($0)) },
                    selection: $draft.subject)
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("MAY").aryaText(AryaFont.label, AryaColor.inkFaint)
                    AryaSegmented(
                        [("use", "Use"), ("approve", "Approve"), ("view", "View")],
                        selection: draft.level
                    ) { draft.level = $0 }
                    Text(AccessText.level(draft.level))
                        .aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
                OptionColumn(
                    title: "On",
                    options: overview.resources.map {
                        ($0.id, AccessText.title($0.id, in: overview.resources))
                    },
                    selection: $draft.resource)
            }
            HStack(spacing: AryaSpace.s2) {
                Button("Grant") { grant(draft) }
                    .buttonStyle(.aryaPrimary(keys: "⌘↩"))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!draft.ready)
                Button("Cancel", action: cancel).buttonStyle(.aryaTertiary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.vertical, AryaSpace.s2)
        .aryaHairline(edge: .bottom)
    }
}

/// A short list of choices, the chosen one checked; scrolls past eight rows.
struct OptionColumn: View {
    let title: String
    let options: [(id: String, label: String)]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.id) { option in
                        Button {
                            selection = option.id
                        } label: {
                            HStack(spacing: AryaSpace.s1) {
                                Text(selection == option.id ? "✓" : " ")
                                    .aryaText(AryaFont.mono, AryaColor.ink)
                                    .frame(width: AccessLayout.check)
                                Text(option.label)
                                    .aryaText(
                                        AryaFont.body,
                                        selection == option.id ? AryaColor.ink : AryaColor.inkMuted
                                    )
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(height: AryaSize.tableRowHeight)
                            .contentShape(Rectangle())
                            .background(selection == option.id ? AryaColor.selection : .clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title) \(option.label)")
                    }
                }
            }
            .frame(width: 200, height: min(CGFloat(options.count), 8) * AryaSize.tableRowHeight)
        }
    }
}

/// Teams and their members, with a quiet New team… and per-team member editing.
struct TeamsList: View {
    let overview: AccessOverview
    let source: (any AccessSettingsSource)?
    let model: AccessModel
    /// Shows "TEAMS n" before New team… (the window page has no tabs to count them).
    var titled = false
    @AryaState private var editing: String?
    @AryaState private var name = ""
    @AryaState private var members: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AryaSpace.s1) {
                if titled {
                    Text("TEAMS").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Text("\(overview.teams.count)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                Spacer()
                Button("New team…") { start(nil) }.buttonStyle(.aryaQuiet)
                    .disabled(source == nil || editing != nil)
            }
            .padding(.vertical, AryaSpace.s2)
            if editing == "" { editor(nil) }
            if overview.teams.isEmpty, editing == nil {
                EmptyState(
                    "No teams yet.",
                    guidance: "A team lets one grant cover several people.")
            }
            ForEach(overview.teams, id: \.id) { team in
                if editing == team.id {
                    editor(team)
                } else {
                    TableRowFrame {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: AryaSpace.s2) {
                                Text(team.name).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                                Text("\(team.members.count)").aryaText(
                                    AryaFont.monoSmall, AryaColor.inkFaint)
                                Spacer(minLength: AryaSpace.s2)
                                Button("Edit") { start(team) }.buttonStyle(.aryaTertiary)
                                    .accessibilityLabel("Edit team \(team.name)")
                            }
                            Text(AccessText.list(team.members.map { AccessText.who($0) }))
                                .aryaText(AryaFont.caption, AryaColor.inkMuted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, AryaSpace.s1)
                    }
                }
            }
        }
    }

    private func start(_ team: AccessTeamSummary?) {
        editing = team?.id ?? ""
        name = team?.name ?? ""
        members = Set(team?.members ?? [])
    }

    private func editor(_ team: AccessTeamSummary?) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            TextField("Team name", text: $name)
                .textFieldStyle(.plain)
                .aryaText(AryaFont.body, AryaColor.ink)
                .padding(AryaSpace.s1)
                .background(AryaColor.raised)
                .clipShape(RoundedRectangle(cornerRadius: AryaRadius.small))
                .frame(width: 240)
            Text("MEMBERS").aryaText(AryaFont.label, AryaColor.inkFaint)
            FlowChecks(people: overview.people, chosen: $members)
            HStack(spacing: AryaSpace.s2) {
                Button(team == nil ? "Create team" : "Save team") { save(team) }
                    .buttonStyle(.aryaQuiet)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || members.isEmpty)
                if let team {
                    Button("Disband") {
                        Task {
                            guard let source else { return }
                            if await model.setTeam(team.id, name: nil, members: [], from: source) {
                                editing = nil
                            }
                        }
                    }
                    .buttonStyle(.aryaTertiary)
                }
                Button("Cancel") { editing = nil }.buttonStyle(.aryaTertiary)
            }
        }
        .padding(.vertical, AryaSpace.s2)
        .aryaHairline(edge: .bottom)
    }

    private func save(_ team: AccessTeamSummary?) {
        let title = name.trimmingCharacters(in: .whitespaces)
        let id =
            team?.id ?? "team:"
            + title.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        Task {
            guard let source else { return }
            if await model.setTeam(id, name: title, members: members.sorted(), from: source) {
                editing = nil
            }
        }
    }
}

/// People as check rows, two columns.
struct FlowChecks: View {
    let people: [String]
    @Binding var chosen: Set<String>

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.fixed(200), alignment: .leading),
                GridItem(.fixed(200), alignment: .leading),
            ],
            alignment: .leading, spacing: 0
        ) {
            ForEach(people, id: \.self) { person in
                Button {
                    if chosen.contains(person) {
                        chosen.remove(person)
                    } else {
                        chosen.insert(person)
                    }
                } label: {
                    HStack(spacing: AryaSpace.s1) {
                        Text(chosen.contains(person) ? "✓" : " ")
                            .aryaText(AryaFont.mono, AryaColor.ink).frame(width: AccessLayout.check)
                        Text(AccessText.subject(person))
                            .aryaText(
                                AryaFont.body,
                                chosen.contains(person) ? AryaColor.ink : AryaColor.inkMuted)
                    }
                    .frame(height: AryaSize.tableRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Member \(AccessText.subject(person))")
            }
        }
    }
}

/// The inspector beside Access: what each level allows and who may change access.
struct AccessInspector: View {
    let model: AccessModel
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("LEVELS").aryaText(AryaFont.label, AryaColor.inkFaint)
                ForEach(["use", "approve", "view"], id: \.self) { level in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        TagPill(level)
                        Text(AccessText.level(level)).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    }
                }
            }
            if let overview = model.overview {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("CAN CHANGE ACCESS").aryaText(AryaFont.label, AryaColor.inkFaint)
                    ForEach(AccessText.admins(overview), id: \.self) { name in
                        Text(name).aryaText(AryaFont.body, AryaColor.ink)
                    }
                }
                if !overview.changes.isEmpty {
                    VStack(alignment: .leading, spacing: AryaSpace.s1) {
                        Text("RECENT CHANGES").aryaText(AryaFont.label, AryaColor.inkFaint)
                        ForEach(overview.changes, id: \.seq) { change in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(AccessText.change(change, in: overview))
                                    .aryaText(AryaFont.caption, AryaColor.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(AccessText.byline(change.by, change.at, now: now))
                                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("ENFORCED").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Text(
                        overview.enforced
                            ? "A steward acts for a person only through their grants."
                            : "Nothing yet: the first grant or team turns it on."
                    )
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
