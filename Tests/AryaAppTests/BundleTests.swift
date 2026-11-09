import Foundation
import Testing

/// Checks `etc/app/Info.plist`, which `just app` copies into `Arya.app`.
@Suite struct BundleTests {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func infoPlistDescribesTheApp() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("etc/app/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        #expect(plist["CFBundleExecutable"] as? String == "AryaApp")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(plist["NSPrincipalClass"] as? String == "NSApplication")
        #expect((plist["CFBundleIdentifier"] as? String)?.isEmpty == false)
    }

    @Test func iconScriptExists() {
        let script = root.appendingPathComponent("etc/app/make-icon.swift").path
        #expect(FileManager.default.fileExists(atPath: script))
    }
}
