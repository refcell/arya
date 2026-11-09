import AryaAdapters
import AryaCore
import Foundation

/// A live MCP server run as a child process (a binding's `command` and `args`), spoken to with
/// newline-delimited JSON-RPC on its stdin and stdout.
public actor ProcessToolUpstream: ToolUpstream {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var nextID: Int64 = 1
    private var waiting: [RPCID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var initialized = false
    private var closed = false

    /// Starts `command` with `args` (looked up on `PATH` when not a path); stderr is discarded.
    public init(command: String, args: [String], environment: [String: String]? = nil) throws {
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        if let environment { process.environment = environment }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let (lines, feed) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        Task { [weak self] in await self?.read(lines) }
    }

    public func listTools() async throws -> [JSONValue] {
        try await ready()
        return try await send("tools/list", [:])["tools"]?.arrayValue ?? []
    }

    public func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        try await ready()
        return try await send("tools/call", ["name": .string(tool), "arguments": arguments])
    }

    /// Ends the server: closes its stdin and terminates it.
    public func close() {
        guard !closed else { return }
        closed = true
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        fail(RPCError(code: RPCErrorCode.internalError, message: "upstream closed"))
    }

    private func ready() async throws {
        guard !initialized else { return }
        _ = try await send(
            "initialize",
            [
                "protocolVersion": .string(BindingProxy.protocolVersion), "capabilities": [:],
                "clientInfo": ["name": "arya-binding-proxy", "version": "0.1.0"],
            ])
        write(.notification(RPCNotification(method: "notifications/initialized")))
        initialized = true
    }

    private func send(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard !closed else {
            throw RPCError(code: RPCErrorCode.internalError, message: "upstream closed")
        }
        let id = RPCID.int(nextID)
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            write(.request(RPCRequest(id: id, method: method, params: params)))
        }
    }

    private func write(_ message: RPCMessage) {
        try? stdin.fileHandleForWriting.write(contentsOf: LineCodec.encode(message))
    }

    private func read(_ chunks: AsyncStream<Data>) async {
        var splitter = LineSplitter()
        for await chunk in chunks {
            for line in splitter.append(chunk) {
                guard case .response(let response)? = try? LineCodec.decode(line),
                    let continuation = waiting.removeValue(forKey: response.id)
                else { continue }
                continuation.resume(with: response.outcome.mapError { $0 as any Error })
            }
        }
        fail(RPCError(code: RPCErrorCode.internalError, message: "upstream exited"))
    }

    private func fail(_ error: RPCError) {
        let pending = waiting
        waiting = [:]
        for continuation in pending.values { continuation.resume(throwing: error) }
    }
}
