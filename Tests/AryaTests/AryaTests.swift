import Foundation
import Testing

@testable import Arya

@Test func moduleLinks() {
    #expect(Arya.name == "Arya")
}

@Test func openCreatesHomeLayout() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-test-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try await Workspace.open(home: home)
    #expect(workspace.home == home)
    for name in ["ledger", "blobs", "casebooks", "cache"] {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: home.appendingPathComponent(name).path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "missing \(name)")
    }
    // Opening again is harmless.
    _ = try await Workspace.open(home: home)
}
