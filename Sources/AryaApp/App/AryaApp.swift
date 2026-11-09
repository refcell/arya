import AppKit
import SwiftUI

/// The macOS app entry point.
@main
struct AryaApp: App {
    init() {
        // Show a Dock icon and menu bar even when launched as a bare binary.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("arya") {
            RootView()
        }
    }
}
