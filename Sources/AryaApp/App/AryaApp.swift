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
    }

    var body: some Scene {
        Window("arya", id: "main") {
            SessionView(session: session)
                .task {
                    guard session.choice == nil else { return }
                    let support = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    await session.open(
                        HomeLocator.resolve(
                            arguments: CommandLine.arguments,
                            environment: ProcessInfo.processInfo.environment,
                            applicationSupport: support))
                }
        }
        .defaultSize(width: 1120, height: 720)
        .windowResizability(.contentMinSize)
        .commands { AryaCommands(session: session) }
    }
}

/// The window content once a home is chosen, or why it is not open.
struct SessionView: View {
    let session: AppSession

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
        .navigationSubtitle(session.subtitle)
    }
}

/// Menu commands: open a home, refresh, go to approvals, and switch tabs by number.
struct AryaCommands: Commands {
    let session: AppSession

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Home…") { openHome() }.keyboardShortcut("o")
            Button("Open Preview Workspace") { Task { await session.open(.preview) } }
        }
        CommandMenu("Go") {
            Button("Approvals") { session.model?.navigation.showApprovals() }
                .keyboardShortcut("0")
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
        Task { await session.open(.home(url)) }
    }
}
