import AppKit
import AryaDesign
import SwiftUI

/// The macOS app entry point: one window onto one arya home.
@main
struct AryaApp: App {
    @AryaState private var session = AppSession()

    init() {
        // Show a Dock icon and menu bar even when launched as a bare binary.
        NSApplication.shared.setActivationPolicy(.regular)
        // Dark whatever the system setting unless the person chose Light (decision 0036).
        Self.apply(AryaAppearance(stored: UserDefaults.standard.string(forKey: Self.appearanceKey)))
    }

    static let appearanceKey = "appearance"

    static func apply(_ appearance: AryaAppearance) {
        NSApplication.shared.appearance = NSAppearance(named: appearance.nsAppearanceName)
    }

    var body: some Scene {
        Window("arya", id: "main") {
            SessionView(session: session)
                .task {
                    guard session.choice == nil else { return }
                    let support = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    let environment = ProcessInfo.processInfo.environment
                    await session.open(
                        HomeLocator.resolve(
                            arguments: CommandLine.arguments, environment: environment,
                            applicationSupport: support),
                        environment: environment)
                    session.enableNotifications()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)
        .windowResizability(.contentMinSize)
        .commands { AryaCommands(session: session) }
        // App settings (home, appearance, text size), opened by the gear or Command-comma.
        Settings {
            AppSettingsView(
                home: session.model?.source.label, governance: session.model?.governance)
        }
    }
}

/// App-wide settings, apart from any steward: where the home is, appearance, and text size.
struct AppSettingsView: View {
    /// The Settings window's content size.
    static let windowSize = CGSize(width: 460, height: 400)

    /// The open home's label; nil before one opens.
    let home: String?
    /// Retention and encryption for the open home (governance lane); nil before one opens.
    var governance: (any GovernanceSource)? = nil
    @AppStorage(AryaApp.appearanceKey) private var appearance = AryaAppearance.dark.rawValue
    @AppStorage(TextScale.defaultsKey) private var textScale = Double(TextScale.standard)

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            section("Home") {
                Text(home ?? "No home open")
                    .aryaText(AryaFont.mono, AryaColor.inkMuted)
            }
            section("Appearance") {
                ChoiceRow(
                    AryaAppearance.allCases.map { ($0, $0.rawValue.capitalized) },
                    selection: AryaAppearance(stored: appearance)
                ) { choice in
                    appearance = choice.rawValue
                    AryaApp.apply(choice)
                }
            }
            section("Text size") {
                ChoiceRow(
                    zip(TextScale.steps, TextScale.labels).map { ($0, $1) },
                    selection: TextScale.normalized(textScale)
                ) { textScale = Double($0) }
            }
            if governance != nil { HomeGovernanceSection(source: governance) }
        }
        .padding(AryaSpace.s4)
        .frame(
            width: Self.windowSize.width, height: Self.windowSize.height, alignment: .topLeading
        )
        .background(AryaColor.canvas)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title).aryaText(AryaFont.label, AryaColor.inkFaint)
            content()
        }
    }
}

/// The window content once a home is chosen, or why it is not open.
struct SessionView: View {
    let session: AppSession
    @AppStorage(TextScale.defaultsKey) private var textScale = Double(TextScale.standard)

    var body: some View {
        Group {
            if let model = session.model {
                RootView(model: model).id(ObjectIdentifier(model))
            } else if let problem = session.problem {
                EmptyState("The home did not open.", guidance: problem)
                    .background(AryaColor.canvas)
            } else {
                AryaColor.canvas
            }
        }
        .frame(minWidth: AryaSize.windowMinWidth, minHeight: AryaSize.windowMinHeight)
        .background(AryaColor.canvas)
        .environment(\.aryaTextScale, TextScale.normalized(textScale))
    }
}

/// Menu commands: open a home, refresh, go to approvals, and switch tabs by number.
struct AryaCommands: Commands {
    let session: AppSession
    @AppStorage(TextScale.defaultsKey) private var textScale = Double(TextScale.standard)
    @AppStorage(AryaApp.appearanceKey) private var appearance = AryaAppearance.dark.rawValue

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Home…") { openHome() }.keyboardShortcut("o")
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { textScale = Double(TextScale.bigger(textScale)) }
                .keyboardShortcut("+")
            Button("Smaller Text") { textScale = Double(TextScale.smaller(textScale)) }
                .keyboardShortcut("-")
            Button("Actual Size") { textScale = Double(TextScale.standard) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Picker("Appearance", selection: $appearance) {
                Text("Dark").tag(AryaAppearance.dark.rawValue)
                Text("Light").tag(AryaAppearance.light.rawValue)
            }
            .onChange(of: appearance) { _, stored in
                AryaApp.apply(AryaAppearance(stored: stored))
            }
            Divider()
        }
        CommandMenu("Steward") {
            Button("New Steward…") { session.model?.stewardSheet = NewStewardDraft() }
                .keyboardShortcut("n")
                .disabled(session.model == nil)
            Button("Edit Charter…") { session.model.map(FeatureRegistry.editCharter) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session.model?.navigation.steward == nil)
            let steward = session.model?.selectedSteward
            Button("Start Run") { Task { await session.model?.startRun() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(steward == nil || steward?.status != .active)
            if steward?.status == .paused {
                Button("Resume") { Task { await session.model?.setPaused(false) } }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            } else {
                Button("Pause") { Task { await session.model?.setPaused(true) } }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(steward?.status != .active)
            }
            Button("Rehearse") { session.model?.navigation.tab = .improve }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(steward == nil)
        }
        CommandMenu("Go") {
            Button("Command Palette…") { session.model?.paletteOpen.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button("Needs You") { session.model?.navigation.showApprovals() }
                .keyboardShortcut("0")
            Button("All Stewards") { session.model?.navigation.showPortfolio() }
                .keyboardShortcut("9")
            Button("Toggle Sidebar") { session.model?.navigation.sidebar.toggle() }
                .keyboardShortcut("\\")
            Button("Toggle Inspector") { session.model?.navigation.inspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Connections") { session.model?.navigation.showConnections() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("People") { session.model?.navigation.showPeople() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Routines") { session.model?.navigation.showRoutines() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            let stewards = Array((session.model?.stewards ?? []).prefix(9).enumerated())
            ForEach(stewards, id: \.element.id) { index, steward in
                Button(steward.name) { session.model?.navigation.select(steward: steward.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            Divider()
            ForEach(Array(StewardTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { session.model?.navigation.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Refresh") { Task { await session.model?.refresh() } }
                .keyboardShortcut("r")
        }
    }

    private func openHome() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose an arya home folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await session.open(.home(url), environment: ProcessInfo.processInfo.environment)
        }
    }
}
