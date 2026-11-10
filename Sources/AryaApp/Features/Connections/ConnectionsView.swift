import Arya
import AryaDesign
import SwiftUI

/// The Connections page: every system a steward can be bound to, what it reads and does (each
/// action with its risk), which stewards use it, a connection test, and its secret, kept only in
/// the credential store (the Keychain in the app). Test is the quiet default; Connect is the one
/// primary action; Disconnect sits behind More with a confirmation. Connect and Disconnect
/// propose a charter change that goes live through the gate on Improve. Selecting a row shows
/// the connection in the inspector.
struct ConnectionsView: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject var tests: ConnectionTestStore
    let stewards: [StewardSummary]
    /// The steward Connect and Disconnect act on.
    let steward: String?
    /// The connection the inspector shows.
    let selected: String?
    let credentials: any CredentialStore
    let selectSteward: (String) -> Void
    let select: (String) -> Void
    /// Tests a connection with its secret.
    let probe: @Sendable (ConnectionsCatalog.Entry, String?) async throws -> ConnectionTest

    @AryaState private var secrets: [String: String] = [:]
    @AryaState private var stored: [String: Bool] = [:]
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
                if let steward {
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
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(catalog.entries) { entry in
                            row(catalog.entry(entry, for: steward), catalog: catalog)
                            AryaHairline()
                        }
                    }
                }
                if !catalog.adapters.isEmpty { adapters(catalog.adapters) }
            }
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Connections")
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

    private func row(_ entry: ConnectionsCatalog.Entry, catalog: ConnectionsCatalog) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text(entry.id).aryaText(AryaFont.monoStrong, AryaColor.ink)
                Text(entry.commandLine).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .lineLimit(1)
                if entry.network {
                    Text("network").aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
                Spacer()
                controls(entry, catalog: catalog)
            }
            Text(ConnectionsText.capabilities(entry))
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text("used by: " + names(entry.connected))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                credential(entry)
            }
            if let test = tests.results[entry.id] {
                Text(ConnectionsText.lastTest(test))
                    .aryaText(AryaFont.monoSmall, Self.color(test))
            }
        }
        .padding(.vertical, AryaSpace.s3)
        .padding(.horizontal, AryaSpace.s2)
        .background(
            selected == entry.id ? AryaColor.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(entry.id) }
        .accessibilityAddTraits(selected == entry.id ? .isSelected : [])
    }

    @ViewBuilder
    private func controls(_ entry: ConnectionsCatalog.Entry, catalog: ConnectionsCatalog)
        -> some View
    {
        let running = tests.testing.contains(entry.id)
        Button(running ? "Testing…" : "Test") { test(entry) }
            .buttonStyle(.aryaTertiary)
            .disabled(running)
        if let steward {
            if catalog.isConnected(entry, steward: steward) {
                Text("connected").aryaText(AryaFont.monoSmall, AryaColor.positive)
                let blocker = catalog.disconnectBlocker(entry, steward: steward)
                Menu("More") {
                    Button("Disconnect…") { confirming = entry.id }
                        .disabled(blocker != nil)
                    if let blocker { Text(blocker) }
                }
                .aryaMenuButton()
                .fixedSize()
                .help("More actions for \(entry.id)")
            } else {
                Button("Connect") { propose(catalog.connectProposal(entry, steward: steward)) }
                    .buttonStyle(.aryaPrimary)
                    .help("Propose adding it to the charter; it goes live through the gate.")
            }
        }
    }

    @ViewBuilder
    private func credential(_ entry: ConnectionsCatalog.Entry) -> some View {
        if stored[entry.id] ?? credentials.hasCredential(for: entry.id) {
            Text("secret: in Keychain").aryaText(AryaFont.monoSmall, AryaColor.positive)
            Button("Remove") { removeSecret(entry.id) }.buttonStyle(.aryaTertiary)
        } else {
            SecureField("secret (token or password)", text: secretBinding(entry.id))
                .textFieldStyle(.plain)
                .aryaText(AryaFont.monoSmall, AryaColor.ink)
                .padding(AryaSpace.s1)
                .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
                .frame(maxWidth: 240)
            Button("Save") { saveSecret(entry.id) }
                .buttonStyle(.aryaTertiary)
                .disabled((secrets[entry.id] ?? "").isEmpty)
        }
    }

    private func adapters(_ adapters: [ConnectionsCatalog.Adapter]) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text("ADAPTERS").aryaText(AryaFont.label, AryaColor.inkFaint)
            ForEach(adapters, id: \.name) { adapter in
                Text("\(adapter.name) · used by: \(names(adapter.stewards))")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            }
        }
    }

    private func names(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "no steward" }
        return ids.map { id in stewards.first { $0.id == id }?.name ?? id }
            .joined(separator: ", ")
    }

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

    private func secretBinding(_ id: String) -> Binding<String> {
        Binding(get: { secrets[id] ?? "" }, set: { secrets[id] = $0 })
    }

    private func saveSecret(_ id: String) {
        do {
            try credentials.setCredential(secrets[id] ?? "", for: id)
            secrets[id] = nil
            stored[id] = true
            note = "Saved the secret for \(id) in the Keychain."
        } catch {
            note = "Could not save the secret for \(id) (\(error))."
        }
    }

    private func removeSecret(_ id: String) {
        do {
            try credentials.removeCredential(for: id)
            stored[id] = false
            note = "Removed the secret for \(id)."
        } catch {
            note = "Could not remove the secret for \(id) (\(error))."
        }
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

/// "For steward: Support inbox triage ▾", a menu of the stewards.
struct StewardPicker: View {
    let stewards: [StewardSummary]
    let selected: String
    let select: (String) -> Void

    var body: some View {
        let name = stewards.first { $0.id == selected }?.name ?? selected
        Menu {
            ForEach(stewards, id: \.id) { steward in
                Button(steward.name) { select(steward.id) }
            }
        } label: {
            Text("For steward: \(name) ▾").aryaText(AryaFont.body, AryaColor.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("For steward: \(name)")
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
                        : entry.actions.map { "\($0.kind) (\($0.risk))" }.joined(separator: ", "))
                fact("Network", entry.network ? "allowed when sandboxed" : "none")
                fact(
                    "Used by",
                    entry.connected.isEmpty
                        ? "no steward"
                        : entry.connected.map { id in stewards.first { $0.id == id }?.name ?? id }
                            .joined(separator: ", "))
                fact(
                    "Secret",
                    credentials.hasCredential(for: entry.id) ? "in Keychain" : "none stored")
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("LAST TEST").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Text(ConnectionsText.lastTest(tests.results[entry.id]))
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
                let running = tests.testing.contains(entry.id)
                Button(running ? "Testing…" : "Test connection") {
                    tests.run(
                        entry, secret: (try? credentials.credential(for: entry.id)) ?? nil,
                        probe: probe)
                }
                .buttonStyle(.aryaQuiet)
                .disabled(running)
            }
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
