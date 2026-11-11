import Arya
import AryaDesign
import SwiftUI

/// The Connections page: every system a steward can be bound to, what it reads and does (each
/// action with its risk), which stewards use it, a connection test, and its secret, kept only in
/// the credential store (the Keychain in the app). It opens on All stewards; a steward scope
/// lists that steward's connections with Disconnect and folds the rest under "Not used by this
/// steward" with a quiet Add to steward…. Both propose a charter change that goes live through
/// the gate on Improve. Selecting a row shows the connection in the inspector.
struct ConnectionsView: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject var tests: ConnectionTestStore
    let stewards: [StewardSummary]
    /// The steward Connect and Disconnect act on; nil is All stewards.
    let steward: String?
    /// The connection the inspector shows.
    let selected: String?
    let credentials: any CredentialStore
    let selectSteward: (String?) -> Void
    let select: (String) -> Void
    /// Tests a connection with its secret.
    let probe: @Sendable (ConnectionsCatalog.Entry, String?) async throws -> ConnectionTest

    @AryaState private var stored: [String: Bool] = [:]
    /// The "Not used by this steward" group is open.
    @AryaState private var unusedOpen = false
    @AryaState private var note: String?
    @AryaState private var confirming: String?

    var body: some View {
        let catalog = ConnectionsCatalog(events: store.events)
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                PageTitle(
                    title: "Connections",
                    subtitle: "Systems stewards read from and act in. Secrets stay in the Keychain."
                )
                if !stewards.isEmpty {
                    StewardPicker(stewards: stewards, selected: steward, select: selectSteward)
                }
                if let note { Text(note).aryaText(AryaFont.caption, AryaColor.inkMuted) }
                if let error = store.writeError {
                    InlineError(error) { store.dismissWriteError() }
                }
                if catalog.entries.isEmpty {
                    EmptyState(
                        "No connections yet.",
                        guidance: "Connections a steward's charter binds appear here.")
                } else {
                    let activity = ConnectionActivity(events: store.events, relays: catalog.relays)
                    let (used, unused) = split(catalog)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(used) { entry in
                            row(
                                catalog.entry(entry, for: steward), catalog: catalog,
                                activity: activity)
                            AryaHairline()
                        }
                    }
                    if !unused.isEmpty {
                        unusedGroup(unused, catalog: catalog, activity: activity)
                    }
                }
                let activity = ConnectionActivity(events: store.events, relays: catalog.relays)
                let ids = Set(catalog.entries.map(\.id))
                HStack(alignment: .top, spacing: AryaSpace.s5) {
                    VStack(alignment: .leading, spacing: AryaSpace.s4) {
                        if !ids.isEmpty { callsStrip(activity, connections: ids) }
                        if !catalog.adapters.isEmpty { adapters(catalog.adapters) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !ids.isEmpty {
                        recentCalls(activity, connections: ids)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Connections")
        .task { await store.loadAdapterLabels() }
        .confirmationDialog(
            confirmTitle, isPresented: confirmBinding, titleVisibility: .visible
        ) {
            if let id = confirming, let steward,
                let entry = catalog.entries.first(where: { $0.id == id })
            {
                Button("Propose disconnecting", role: .destructive) {
                    propose(catalog.disconnectProposal(entry, steward: steward))
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("The steward keeps it until the proposal passes the gate on Improve.")
        }
    }

    private func row(
        _ entry: ConnectionsCatalog.Entry, catalog: ConnectionsCatalog,
        activity: ConnectionActivity
    ) -> some View {
        let calls = activity.count(entry.id, now: store.now)
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .center, spacing: AryaSpace.s3) {
                Text(entry.id).aryaText(AryaFont.monoStrong, AryaColor.ink)
                    .frame(minWidth: 72, alignment: .leading)
                testStatus(entry, last: activity.lastSettled(entry.id))
                Spacer(minLength: AryaSpace.s3)
                Sparkline(activity.daily(entry.id, now: store.now))
                    .accessibilityLabel("Calls per day this week")
                Text(calls == 1 ? "1 call · 7d" : "\(calls) calls · 7d")
                    .aryaText(
                        AryaFont.monoSmall, calls == 0 ? AryaColor.inkFaint : AryaColor.inkMuted
                    )
                    .frame(width: 88, alignment: .trailing)
                controls(entry, catalog: catalog)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
                if !entry.read.isEmpty {
                    Text("reads " + entry.read.joined(separator: ", "))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        .fixedSize()
                }
                if !entry.actions.isEmpty { actions(entry).fixedSize() }
                Text("used by " + RosterText.names(entry.connected.map(name)))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .layoutPriority(-1)
                Text(ConnectionsText.secret(stored: hasSecret(entry.id), network: entry.network))
                    .aryaText(
                        AryaFont.monoSmall,
                        hasSecret(entry.id) ? AryaColor.positive : AryaColor.inkFaint)
                if entry.network {
                    Text("network").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, AryaSpace.s2)
        .padding(.horizontal, AryaSpace.s2)
        .background(
            selected == entry.id ? AryaColor.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(entry.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected == entry.id ? .isSelected : [])
    }

    /// The scope's connections and, in a steward scope, the ones it does not use.
    private func split(_ catalog: ConnectionsCatalog)
        -> ([ConnectionsCatalog.Entry], [ConnectionsCatalog.Entry])
    {
        guard let steward else { return (catalog.entries, []) }
        let used = catalog.entries.filter { catalog.isConnected($0, steward: steward) }
        return (used, catalog.entries.filter { !catalog.isConnected($0, steward: steward) })
    }

    /// "Not used by this steward (7)", collapsed until opened.
    private func unusedGroup(
        _ entries: [ConnectionsCatalog.Entry], catalog: ConnectionsCatalog,
        activity: ConnectionActivity
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AryaMotion.quick) { unusedOpen.toggle() }
            } label: {
                HStack(spacing: AryaSpace.s1) {
                    DisclosureChevron(isExpanded: unusedOpen)
                    Text("NOT USED BY THIS STEWARD (\(entries.count))")
                        .aryaText(AryaFont.label, AryaColor.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not used by this steward, \(entries.count)")
            .padding(.vertical, AryaSpace.s2)
            if unusedOpen {
                ForEach(entries) { entry in
                    row(catalog.entry(entry, for: steward), catalog: catalog, activity: activity)
                    AryaHairline()
                }
            }
        }
    }

    /// "label low · reply high", each kind in its risk's color.
    private func actions(_ entry: ConnectionsCatalog.Entry) -> some View {
        HStack(spacing: AryaSpace.s2) {
            Text("does").aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            ForEach(entry.actions, id: \.kind) { action in
                Text("\(ActionWords.kind(action.kind)) \(action.risk)")
                    .aryaText(AryaFont.monoSmall, Self.riskColor(action.risk))
            }
        }
    }

    /// The last test in one line, else the ledger's last call, else "not tested", with a dot.
    private func testStatus(_ entry: ConnectionsCatalog.Entry, last: ConnectionActivity.Call?)
        -> some View
    {
        let test = tests.results[entry.id]
        return HStack(spacing: AryaSpace.s1) {
            if tests.testing.contains(entry.id) {
                StatusDot(.running)
                Text("testing…").aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            } else if let test {
                StatusDot(test.complete ? .passed : test.ok ? .waiting : .failed)
                Text(ConnectionsText.lastTest(test)).aryaText(AryaFont.monoSmall, Self.color(test))
                    .lineLimit(1)
            } else if let evidence = ConnectionsText.evidence(last, now: store.now) {
                StatusDot(last?.kind == .failed ? .failed : .passed)
                Text(evidence)
                    .aryaText(
                        AryaFont.monoSmall,
                        last?.kind == .failed ? AryaColor.negative : AryaColor.inkMuted
                    )
                    .lineLimit(1)
            } else {
                Text("not tested").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
        }
    }

    @ViewBuilder
    private func controls(_ entry: ConnectionsCatalog.Entry, catalog: ConnectionsCatalog)
        -> some View
    {
        let running = tests.testing.contains(entry.id)
        Button("Test") { test(entry) }
            .buttonStyle(.aryaTertiary)
            .disabled(running)
            .help("Start \(entry.id) and list its tools")
        if let steward {
            if catalog.isConnected(entry, steward: steward) {
                let blocker = catalog.disconnectBlocker(entry, steward: steward)
                Button("Disconnect") { confirming = entry.id }
                    .buttonStyle(.aryaSecondary)
                    .disabled(blocker != nil)
                    .help(blocker ?? "Propose removing it from the charter")
            } else {
                Button("Add to steward…") {
                    propose(catalog.connectProposal(entry, steward: steward))
                }
                .buttonStyle(.aryaTertiary)
                .help("Propose adding it to the charter; it goes live through the gate.")
            }
        }
    }

    private func hasSecret(_ id: String) -> Bool {
        stored[id] ?? credentials.hasCredential(for: id)
    }

    static func riskColor(_ risk: String) -> Color {
        switch risk {
        case "high": AryaColor.negative
        case "medium": AryaColor.warning
        default: AryaColor.inkMuted
        }
    }

    /// The newest calls through any connection, so the page shows what stewards do with them.
    /// Person bindings are not connections, so replies to people stay on People.
    private func recentCalls(_ activity: ConnectionActivity, connections: Set<String>)
        -> some View
    {
        let calls = activity.calls.filter { connections.contains($0.key) }
            .flatMap { id, calls in calls.map { (id, $0) } }
            .sorted { $0.1.at > $1.1.at }.prefix(18)
        let names = StewardNames.build(events: store.events)
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text("RECENT CALLS").aryaText(AryaFont.label, AryaColor.inkFaint)
            if calls.isEmpty {
                Text("No calls yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(Array(calls), id: \.1.id) { connection, call in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                    Text(call.kind.rawValue)
                        .aryaText(AryaFont.monoSmall, ConnectionInspector.color(call.kind))
                        .frame(width: 64, alignment: .leading)
                    Text(connection).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        .frame(width: 56, alignment: .leading)
                    Text(call.what).aryaText(AryaFont.monoSmall, AryaColor.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: AryaSpace.s3)
                    Text(call.steward.map { names[$0] ?? $0 } ?? "")
                        .aryaText(AryaFont.caption, AryaColor.inkFaint).lineLimit(1)
                    Text(FeatureTime.relative(call.at, now: store.now))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(minHeight: 20)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Calls across the listed connections per day for two weeks, today last.
    private func callsStrip(_ activity: ConnectionActivity, connections: Set<String>)
        -> some View
    {
        let days = 14
        var totals = [Double](repeating: 0, count: days)
        for id in connections {
            for (index, value) in activity.daily(id, now: store.now, days: days).enumerated()
            where index < days {
                totals[index] += value
            }
        }
        let peak = max(totals.max() ?? 0, 1)
        let barHeight: CGFloat = 44
        return VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                Text("CALLS · 14 DAYS").aryaText(AryaFont.label, AryaColor.inkFaint)
                Spacer()
                Text("\(Int(totals.reduce(0, +))) calls · \(Int(totals.last ?? 0)) today")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(totals.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: AryaRadius.small)
                        .fill(index == days - 1 ? AryaColor.positive : AryaColor.inkFaint)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, barHeight * value / peak))
                }
            }
            .frame(height: barHeight, alignment: .bottom)
            HStack {
                Text("14d ago").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                Spacer()
                Text("today").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calls per day for two weeks, \(Int(totals.reduce(0, +))) in all")
    }

    private func adapters(_ adapters: [ConnectionsCatalog.Adapter]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADAPTERS").aryaText(AryaFont.label, AryaColor.inkFaint)
                .padding(.bottom, AryaSpace.s1)
            ForEach(adapters, id: \.name) { adapter in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                        Text(store.adapterLabels[adapter.name] ?? adapter.name)
                            .aryaText(AryaFont.bodyStrong, AryaColor.ink)
                            .lineLimit(1)
                            .help("Adapter profile \(adapter.name)")
                        Spacer(minLength: AryaSpace.s3)
                        Text(
                            adapter.stewards.count == 1
                                ? "1 steward" : "\(adapter.stewards.count) stewards"
                        )
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                    Text("used by " + RosterText.names(adapter.stewards.map(name), shown: 3))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AryaSpace.s2)
                .padding(.vertical, AryaSpace.s1)
                .frame(minHeight: AryaSize.rowHeight)
                .accessibilityElement(children: .combine)
                AryaHairline()
            }
        }
    }

    private func name(_ id: String) -> String { stewards.first { $0.id == id }?.name ?? id }

    static func color(_ test: ConnectionTest) -> Color {
        test.complete ? AryaColor.positive : test.ok ? AryaColor.warning : AryaColor.negative
    }

    private var confirmTitle: String {
        let name = stewards.first { $0.id == steward }?.name ?? steward ?? "this steward"
        return "Disconnect \(confirming ?? "") from \(name)?"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private func test(_ entry: ConnectionsCatalog.Entry) {
        select(entry.id)
        tests.run(entry, secret: (try? credentials.credential(for: entry.id)) ?? nil, probe: probe)
    }

    private func propose(_ proposal: CharterProposal?) {
        confirming = nil
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

/// The steward a page acts on: a segmented control for up to four stewards (STYLE.md caps
/// segments at four), else "For steward: Support inbox triage ▾", a menu.
struct StewardPicker: View {
    let stewards: [StewardSummary]
    /// nil is All stewards.
    let selected: String?
    let select: (String?) -> Void

    var body: some View {
        let name = selected.map { id in stewards.first { $0.id == id }?.name ?? id }
        Menu {
            Button("All stewards") { select(nil) }
            Divider()
            ForEach(stewards, id: \.id) { steward in
                Button(steward.name) { select(steward.id) }
            }
        } label: {
            Text("\(name ?? "All stewards") ▾").aryaText(AryaFont.body, AryaColor.ink)
        }
        .aryaMenuButton()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Scope: \(name ?? "All stewards")")
    }
}

/// The inspector for the selected connection: what it reads and does, the stewards using it,
/// its secret's status, and the last test, with Test.
struct ConnectionInspector: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject var tests: ConnectionTestStore
    let connection: String
    let steward: String?
    let stewards: [StewardSummary]
    let credentials: any CredentialStore
    let probe: @Sendable (ConnectionsCatalog.Entry, String?) async throws -> ConnectionTest

    @AryaState private var draft = ""
    @AryaState private var stored: [String: Bool] = [:]

    var body: some View {
        let catalog = ConnectionsCatalog(events: store.events)
        if let found = catalog.entries.first(where: { $0.id == connection }) {
            let entry = catalog.entry(found, for: steward)
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text(entry.id).aryaText(AryaFont.monoStrong, AryaColor.ink)
                    Text(entry.commandLine).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                fact("Reads", entry.read.isEmpty ? "nothing" : entry.read.joined(separator: ", "))
                fact(
                    "Does",
                    entry.actions.isEmpty
                        ? "nothing"
                        : entry.actions.map { "\(ActionWords.kind($0.kind)) \($0.risk)" }
                            .joined(separator: ", "))
                fact("Network", entry.network ? "allowed when sandboxed" : "none")
                fact(
                    "Used by",
                    entry.connected.isEmpty
                        ? "no steward"
                        : entry.connected.map { id in stewards.first { $0.id == id }?.name ?? id }
                            .joined(separator: ", "))
                if let carries = ConnectionsText.carries(
                    catalog, entry: entry, events: store.events)
                {
                    fact("Carries", carries)
                }
                let relayed = ConnectionsText.relayed(entry.id, events: store.events)
                if !relayed.isEmpty {
                    section("Last messages") {
                        ForEach(relayed, id: \.id) { event in
                            line(
                                PeopleDirectory.displayName(event.payload["from"]?.string ?? ""),
                                event.payload["text"]?.string ?? "", at: event.at)
                        }
                    }
                }
                let activity = ConnectionActivity(events: store.events, relays: catalog.relays)
                section("Recent calls") {
                    let calls = activity.recent(entry.id)
                    if calls.isEmpty {
                        Text("No calls yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                    ForEach(calls) { call in
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            Text(call.kind.rawValue)
                                .aryaText(AryaFont.monoSmall, Self.color(call.kind))
                                .frame(width: 56, alignment: .leading)
                            Text(call.what).aryaText(AryaFont.monoSmall, AryaColor.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(FeatureTime.relative(call.at, now: store.now))
                                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                section("Last test") {
                    Text(
                        tests.results[entry.id] == nil
                            ? ConnectionsText.evidence(
                                activity.lastSettled(entry.id), now: store.now
                            )
                            .map { "Not tested this session · \($0)" } ?? "Not tested yet"
                            : ConnectionsText.lastTest(tests.results[entry.id])
                    )
                    .aryaText(
                        AryaFont.monoSmall,
                        tests.results[entry.id].map(ConnectionsView.color) ?? AryaColor.inkMuted
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    if let tools = tests.results[entry.id]?.tools, !tools.isEmpty {
                        Text("tools: " + tools.joined(separator: ", "))
                            .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                section("Secret") { secret(entry.id) }
                let running = tests.testing.contains(entry.id)
                HStack {
                    Spacer()
                    Button(running ? "Testing…" : "Test connection") {
                        tests.run(
                            entry, secret: (try? credentials.credential(for: entry.id)) ?? nil,
                            probe: probe)
                    }
                    .buttonStyle(.aryaSecondary)
                    .disabled(running)
                }
            }
        }
    }

    @ViewBuilder
    private func secret(_ id: String) -> some View {
        if stored[id] ?? credentials.hasCredential(for: id) {
            HStack(spacing: AryaSpace.s2) {
                Text("in Keychain").aryaText(AryaFont.monoSmall, AryaColor.positive)
                Spacer()
                Button("Remove") {
                    stored[id] = (try? credentials.removeCredential(for: id)) == nil
                }
                .buttonStyle(.aryaTertiary)
            }
        } else {
            HStack(spacing: AryaSpace.s2) {
                SecureField("token or password", text: $draft)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.monoSmall, AryaColor.ink)
                    .padding(.horizontal, AryaSpace.s2)
                    .frame(height: AryaSize.buttonHeight)
                    .background(
                        AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
                Button("Save") {
                    if (try? credentials.setCredential(draft, for: id)) != nil {
                        draft = ""
                        stored[id] = true
                    }
                }
                .buttonStyle(.aryaSecondary)
                .disabled(draft.isEmpty)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
            content()
        }
    }

    private func line(_ who: String, _ text: String, at: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(who).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                .frame(width: 56, alignment: .leading)
            Text(text).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(2)
            Spacer(minLength: 0)
            Text(FeatureTime.relative(at, now: store.now))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        }
        .accessibilityElement(children: .combine)
    }

    static func color(_ kind: ConnectionActivity.Call.Kind) -> Color {
        switch kind {
        case .did: AryaColor.positive
        case .failed: AryaColor.negative
        case .proposed: AryaColor.warning
        case .read, .received: AryaColor.inkMuted
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

/// A connection test failure in one sentence.
struct ConnectionsFailure: Error, Hashable, Sendable {
    var text: String

    init(_ error: any Error) {
        switch error {
        case FeatureReadError.unavailable(let what): text = "\(what) is not available here"
        default: text = FeatureStore.sentence(error)
        }
    }
}
