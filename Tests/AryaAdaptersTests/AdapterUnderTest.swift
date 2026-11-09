import AryaCore
import Foundation

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
