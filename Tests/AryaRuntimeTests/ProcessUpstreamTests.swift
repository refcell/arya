import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

/// A tiny MCP server in `sh`: requests arrive as canonical JSON, so `id` comes first.
private let server = #"""
    #!/bin/sh
    head='{"id":%s,"jsonrpc":"2.0","result":'
    init='{"capabilities":{"tools":{}},"protocolVersion":"2025-06-18"}}'
    list='{"tools":[{"name":"get"},{"name":"update"}]}}'
    call='{"content":[],"isError":false,"structuredContent":{"title":"From process"}}}'
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*) printf "$head$init\n" "$id";;
        *'"method":"tools/list"'*) printf "$head$list\n" "$id";;
        *'"method":"tools/call"'*) printf "$head$call\n" "$id";;
      esac
    done
    """#

private func serverScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-mcp-\(ProcessInfo.processInfo.globallyUniqueString).sh")
    try Data(server.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Test func processUpstreamSpeaksMCPOverStdio() async throws {
    let script = try serverScript()
    defer { try? FileManager.default.removeItem(at: script) }
    let upstream = try ProcessToolUpstream(command: script.path, args: [])
    let tools = try await upstream.listTools()
    #expect(tools.compactMap { $0["name"]?.stringValue } == ["get", "update"])
    let answer = try await upstream.call("get", arguments: ["id": "ISSUE-7"])
    #expect(answer["structuredContent"]?["title"] == "From process")
    await upstream.close()
    await #expect(throws: RPCError.self) { _ = try await upstream.listTools() }
}

@Test func liveProxyOverAProcessExposesOnlyReadTools() async throws {
    let script = try serverScript()
    defer { try? FileManager.default.removeItem(at: script) }
    let upstream = try ProcessToolUpstream(command: script.path, args: [])
    defer { Task { await upstream.close() } }
    let binding = CharterBinding.mcp("tracker", command: script.path, read: ["get"])
    let proxy = BindingProxy(binding: binding, source: .live(upstream), recorder: nil)
    let listed = try await proxy.handle(.request(RPCRequest(id: .int(1), method: "tools/list")))
    guard case .response(let response)? = listed, case .success(let value) = response.outcome
    else {
        Issue.record("tools/list failed")
        return
    }
    #expect(value["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["get"])
}
