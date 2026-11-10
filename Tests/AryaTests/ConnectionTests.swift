import Foundation
import Testing

@testable import Arya

/// A tiny MCP server in `sh` that lists `search` and `get`, and writes the credential it was
/// started with to the file named by its first argument.
private let listingServer = #"""
    #!/bin/sh
    printf '%s' "$ARYA_CREDENTIAL" > "$1"
    head='{"id":%s,"jsonrpc":"2.0","result":'
    init='{"capabilities":{"tools":{}},"protocolVersion":"2025-06-18"}}'
    list='{"tools":[{"name":"search"},{"name":"get"}]}}'
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*) printf "$head$init\n" "$id";;
        *'"method":"tools/list"'*) printf "$head$list\n" "$id";;
        *'"method":"ping"'*) printf "$head{}}\n" "$id";;
      esac
    done
    """#

/// A server that never answers.
private let silent = "#!/bin/sh\nwhile IFS= read -r line; do :; done\n"

private func script(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-conn-\(ProcessInfo.processInfo.globallyUniqueString).sh")
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Test func probeListsToolsAndPassesTheCredential() async throws {
    let server = try script(listingServer)
    let seen = server.appendingPathExtension("seen")
    defer {
        try? FileManager.default.removeItem(at: server)
        try? FileManager.default.removeItem(at: seen)
    }
    let environment = ConnectionCredential.environment(
        ["PATH": "/usr/bin:/bin"], secret: "token-123")
    let probe = await ConnectionTest.run(
        command: server.path, args: [seen.path], declared: ["search", "get", "label", "get"],
        environment: environment)
    #expect(probe.ok, "\(probe.problem ?? "")")
    #expect(probe.tools == ["search", "get"])
    #expect(probe.missing == ["label"])
    #expect(!probe.complete)
    #expect(try String(contentsOf: seen, encoding: .utf8) == "token-123")
}

@Test func probeTimesOutOnASilentServer() async throws {
    let server = try script(silent)
    defer { try? FileManager.default.removeItem(at: server) }
    let probe = await ConnectionTest.run(
        command: server.path, args: [], declared: [], environment: [:], timeoutSeconds: 1)
    #expect(!probe.ok)
    #expect(probe.problem != nil)
}

@Test func probeReportsAMissingCommand() async throws {
    let probe = await ConnectionTest.run(
        command: "/nonexistent/arya-no-such-server", args: [], declared: [], environment: [:],
        timeoutSeconds: 2)
    #expect(!probe.ok && !probe.complete)
    #expect(probe.problem != nil)
}

@Test func credentialEnvironmentOnlyAddsANonEmptySecret() {
    #expect(ConnectionCredential.environment(["A": "1"], secret: nil) == ["A": "1"])
    #expect(ConnectionCredential.environment(["A": "1"], secret: "") == ["A": "1"])
    #expect(
        ConnectionCredential.environment(["A": "1"], secret: "s")
            == ["A": "1", ConnectionCredential.variable: "s"])
}

@Test func memoryCredentialStoreKeepsSecretsByConnection() throws {
    let store = MemoryCredentialStore()
    #expect(!store.hasCredential(for: "tracker"))
    try store.setCredential("one", for: "tracker")
    try store.setCredential("two", for: "tracker")
    #expect(try store.credential(for: "tracker") == "two")
    #expect(!store.hasCredential(for: "inbox"))
    try store.removeCredential(for: "tracker")
    try store.removeCredential(for: "tracker")
    #expect(!store.hasCredential(for: "tracker"))
}
