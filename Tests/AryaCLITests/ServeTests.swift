import Foundation
import Testing

@testable import AryaCLI

/// A fake `launchctl` that records its calls and answers with `status`.
private final class FakeLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let status: Int32

    init(status: Int32 = 0) { self.status = status }

    var calls: [[String]] { lock.withLock { recorded } }

    func items(in agents: URL) -> LoginItems {
        LoginItems(agents: agents, domain: "gui/501") { arguments in
            self.lock.withLock { self.recorded.append(arguments) }
            return self.status
        }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-serve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func launchAgentRunsServeForTheHomeAtLogin() throws {
    let agent = LaunchAgent(binary: "/opt/arya/bin/arya", home: "/tmp/demo", every: 30)
    let data = try agent.plist()
    let plist = try #require(
        try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == "app.arya.serve")
    #expect(
        plist["ProgramArguments"] as? [String]
            == ["/opt/arya/bin/arya", "--home", "/tmp/demo", "serve", "--every", "30"])
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    #expect(plist["StandardErrorPath"] as? String == "/tmp/demo/logs/serve.log")
}

@Test func installWritesThePlistAndLoadsIt() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agents = root.appendingPathComponent("LaunchAgents")
    let home = root.appendingPathComponent("home").path
    let launchctl = FakeLaunchctl()
    let items = launchctl.items(in: agents)

    let report = try items.install(LaunchAgent(binary: "/bin/arya", home: home, every: 60))

    #expect(report.state == .installed)
    #expect(FileManager.default.fileExists(atPath: items.plistURL.path))
    #expect(FileManager.default.fileExists(atPath: home + "/logs"))
    #expect(
        launchctl.calls == [
            ["bootout", "gui/501/app.arya.serve"],
            ["bootstrap", "gui/501", items.plistURL.path],
        ])
}

@Test func failedBootstrapIsReported() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let items = FakeLaunchctl(status: 5).items(in: root)
    #expect(throws: CLIError.self) {
        try items.install(LaunchAgent(binary: "/bin/arya", home: root.path, every: 60))
    }
}

@Test func uninstallRemovesThePlistAndToleratesAbsence() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchctl = FakeLaunchctl()
    let items = launchctl.items(in: root)
    _ = try items.install(LaunchAgent(binary: "/bin/arya", home: root.path, every: 60))

    #expect(try items.uninstall().state == .removed)
    #expect(!FileManager.default.fileExists(atPath: items.plistURL.path))
    #expect(try items.uninstall().state == .removed)
    #expect(launchctl.calls.last == ["bootout", "gui/501/app.arya.serve"])
}

@Test func serveCommandsParseEvery() async {
    let backend = FakeBackend()
    #expect(await runCLI(["serve"], backend: backend).0 == .ok)
    #expect(await runCLI(["serve", "--every", "15"], backend: backend).0 == .ok)
    #expect(await runCLI(["serve", "install", "--every", "120"], backend: backend).0 == .ok)
    #expect(await runCLI(["serve", "uninstall"], backend: backend).0 == .ok)
    #expect(backend.calls == ["serve 60", "serve 15", "install 120", "uninstall"])
    #expect(await runCLI(["serve", "--every", "0"], backend: backend).0 == .usage)
}
