import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// Marks the test bundle so tests can find binaries built next to it.
final class TestBundleMarker {}

/// The adapter process the conformance suite and process tests run.
enum AdapterUnderTest {
    /// The directory that holds the built products (`arya-fake-adapter` among them).
    static let productsDirectory = Bundle(for: TestBundleMarker.self).bundleURL
        .deletingLastPathComponent()

    static let fakeAdapterPath = productsDirectory.appendingPathComponent("arya-fake-adapter")
        .path

    /// The test process's environment; tests may read it, library code may not.
    static let environment = ProcessInfo.processInfo.environment

    /// `ARYA_ADAPTER_CMD` split on spaces, or the fake adapter with the conformance script.
    static var command: AdapterCommand {
        if let custom = environment["ARYA_ADAPTER_CMD"], !custom.isEmpty {
            let parts = custom.split(separator: " ").map(String.init)
            return AdapterCommand(
                executable: parts[0], arguments: Array(parts.dropFirst()),
                environment: environment)
        }
        return fake(script: "conformance-script.json")
    }

    /// The adapters the conformance suite checks: `ARYA_ADAPTER_CMD` alone when set, otherwise
    /// the fake adapter and the exec adapter running a shell agent.
    static var conformanceTargets: [ConformanceTarget] {
        if let custom = environment["ARYA_ADAPTER_CMD"], !custom.isEmpty {
            return [ConformanceTarget(name: custom, command: command)]
        }
        return [
            ConformanceTarget(name: "fake", command: command),
            ConformanceTarget(name: "exec", command: execConformanceCommand),
        ]
    }

    /// `arya-exec-adapter` with a profile whose agent is a short shell script, written to a
    /// fixed directory under the temp directory.
    static let execConformanceCommand: AdapterCommand = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-conformance-exec")
        let script = directory.appendingPathComponent("agent.sh")
        let profiles = directory.appendingPathComponent("adapters.json")
        let body = "#!/bin/sh\ncat > /dev/null\nsleep 0.2\nprintf '```json\\n{}\\n```\\n'\n"
        let book = AdapterProfiles(profiles: [
            "agent": AdapterProfile(kind: .exec, command: script.path, args: ["medium": []])
        ])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        try? JSONEncoder().encode(book).write(to: profiles)
        return AdapterCommand(
            executable: productsDirectory.appendingPathComponent("arya-exec-adapter").path,
            arguments: ["--profile", "agent", "--profiles", profiles.path],
            environment: ["PATH": "/usr/bin:/bin"])
    }()

    /// The fake adapter binary running a fixture script.
    static func fake(script: String) -> AdapterCommand {
        AdapterCommand(
            executable: fakeAdapterPath, arguments: ["--script", Fixtures.url(script).path],
            environment: ["PATH": "/usr/bin:/bin"])
    }

    static func launch(
        _ command: AdapterCommand = command, stderr: StderrBuffer = StderrBuffer(),
        timeouts: ConnectionTimeouts = .standard
    ) throws -> AdapterConnection {
        try AdapterConnection.launch(command, stderr: stderr, timeouts: timeouts)
    }
}

/// One adapter the conformance suite runs against.
struct ConformanceTarget: Sendable, CustomTestStringConvertible {
    let name: String
    let command: AdapterCommand
    var testDescription: String { name }
}
