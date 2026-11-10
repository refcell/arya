import Arya
import AryaDesign
import SwiftUI

/// The Connections page: every system a steward can be bound to, what it can read and do (each
/// action with its risk), which stewards use it, a connection test, and its secret, kept only in
/// the credential store (the Keychain in the app). Connect and Disconnect propose a charter
/// change that goes live through the gate on Improve.
struct ConnectionsView: View {
    @ObservedObject var store: FeatureStore
    let stewards: [StewardSummary]
    /// The steward Connect and Disconnect act on.
    let steward: String?
    let credentials: any CredentialStore
    let selectSteward: (String) -> Void
    /// Tests a connection with its secret; returns the tools it lists.
    let probe: @Sendable (ConnectionsCatalog.Entry, String?) async throws -> ConnectionProbe

    @AryaState private var results: [String: Result<ConnectionProbe, ConnectionsFailure>] = [:]
    @AryaState private var testing: Set<String> = []
    @AryaState private var secrets: [String: String] = [:]
    @AryaState private var stored: [String: Bool] = [:]
    @AryaState private var note: String?

    var body: some View {
        let catalog = ConnectionsCatalog(events: store.events)
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s5) {
                PageTitle(
                    title: "Connections",
                    subtitle: "Systems stewards read from and act in. Secrets stay in the Keychain."
                )
                if stewards.count > 1, let steward {
                    ChoiceRow(stewards.map { ($0.id, $0.name) }, selection: steward) {
                        selectSteward($0)
                    }
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
                    label("Systems")
                    ForEach(catalog.entries) { entry in
                        row(catalog.entry(entry, for: steward), catalog: catalog)
                        AryaHairline()
                    }
                }
                if !catalog.adapters.isEmpty { adapters(catalog.adapters) }
            }
            .padding(.horizontal, AryaSize.pagePadding)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Connections")
    }

    private func row(_ entry: ConnectionsCatalog.Entry, catalog: ConnectionsCatalog) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text(entry.id).aryaText(AryaFont.monoStrong, AryaColor.ink)
                Text(entry.commandLine).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .lineLimit(1)
                if entry.network { Chip("network") }
                Spacer()
                controls(entry, catalog: catalog)
            }
            if !entry.read.isEmpty {
                field("Reads") { ForEach(entry.read, id: \.self) { Chip($0) } }
            }
            if !entry.actions.isEmpty {
                field("Actions") {
                    ForEach(entry.actions, id: \.kind) { action in
                        Chip(
                            "\(action.kind) · \(action.risk)",
                            textColor: Self.color(action.risk))
                    }
                }
            }
            field("Used by") {
                Text(names(entry.connected))
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
            }
            credential(entry)
            if let result = results[entry.id] { testLine(result) }
        }
        .padding(.vertical, AryaSpace.s2)
    }

    @ViewBuilder
    private func controls(_ entry: ConnectionsCatalog.Entry, catalog: ConnectionsCatalog)
        -> some View
    {
        Button(testing.contains(entry.id) ? "Testing…" : "Test") { test(entry) }
            .buttonStyle(.aryaTertiary)
            .disabled(testing.contains(entry.id))
        if let steward {
            if catalog.isConnected(entry, steward: steward) {
                let blocker = catalog.disconnectBlocker(entry, steward: steward)
                Button("Disconnect") {
                    propose(catalog.disconnectProposal(entry, steward: steward))
                }
                .buttonStyle(.aryaQuiet)
                .disabled(blocker != nil)
                .help(blocker ?? "Propose removing it from the charter.")
            } else {
                Button("Connect") { propose(catalog.connectProposal(entry, steward: steward)) }
                    .buttonStyle(.aryaSecondary)
                    .help("Propose adding it to the charter; it goes live through the gate.")
            }
        }
    }

    @ViewBuilder
    private func credential(_ entry: ConnectionsCatalog.Entry) -> some View {
        let has = stored[entry.id] ?? credentials.hasCredential(for: entry.id)
        field("Secret") {
            if has {
                Text("Stored in Keychain").aryaText(AryaFont.caption, AryaColor.positive)
                Button("Remove") { removeSecret(entry.id) }.buttonStyle(.aryaTertiary)
            } else {
                SecureField("Token or password", text: secretBinding(entry.id))
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.mono, AryaColor.ink)
                    .padding(AryaSpace.s1)
                    .background(
                        AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small)
                    )
                    .frame(maxWidth: 260)
                Button("Save") { saveSecret(entry.id) }
                    .buttonStyle(.aryaTertiary)
                    .disabled((secrets[entry.id] ?? "").isEmpty)
            }
        }
    }

    @ViewBuilder
    private func testLine(_ result: Result<ConnectionProbe, ConnectionsFailure>) -> some View {
        switch result {
        case .success(let probe):
            Text(ConnectionTestText.line(tools: probe.tools, missing: probe.missing))
                .aryaText(
                    AryaFont.monoSmall, probe.complete ? AryaColor.positive : AryaColor.warning)
        case .failure(let failure):
            Text("Failed · " + failure.text).aryaText(AryaFont.monoSmall, AryaColor.negative)
        }
    }

    private func adapters(_ adapters: [ConnectionsCatalog.Adapter]) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            label("Adapters")
            ForEach(adapters, id: \.name) { adapter in
                HStack(spacing: AryaSpace.s3) {
                    Text(adapter.name).aryaText(AryaFont.monoStrong, AryaColor.ink)
                    Text(names(adapter.stewards)).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(alignment: .center, spacing: AryaSpace.s2) {
            Text(title.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(width: 72, alignment: .leading)
            content()
        }
    }

    private func names(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "No steward" }
        return ids.map { id in stewards.first { $0.id == id }?.name ?? id }
            .joined(separator: ", ")
    }

    static func color(_ risk: String) -> Color {
        switch risk {
        case "high": AryaColor.negative
        case "medium": AryaColor.warning
        default: AryaColor.inkMuted
        }
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
        testing.insert(entry.id)
        let secret = (try? credentials.credential(for: entry.id)) ?? nil
        Task {
            do {
                results[entry.id] = .success(try await probe(entry, secret))
            } catch {
                results[entry.id] = .failure(ConnectionsFailure(error))
            }
            testing.remove(entry.id)
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

/// A connection test failure in one sentence.
struct ConnectionsFailure: Error, Hashable, Sendable {
    var text: String

    init(_ error: any Error) {
        switch error {
        case ConnectionProbeError.launch(let detail): text = "could not start: \(detail)"
        case ConnectionProbeError.timedOut(let seconds): text = "no answer in \(seconds)s"
        case ConnectionProbeError.failed(let detail): text = detail
        case FeatureReadError.unavailable(let what): text = "\(what) is not available here"
        default: text = FeatureStore.sentence(error)
        }
    }
}
