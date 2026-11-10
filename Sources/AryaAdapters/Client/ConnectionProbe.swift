import AryaCore
import Foundation

/// The outcome of testing an adapter command: who answered and what it can do, or why not.
public struct AdapterProbeReport: Sendable, Hashable, Codable {
    public var ok: Bool
    public var adapter: PeerInfo?
    public var capabilities: Capabilities?
    /// Round trip of `initialize`, in milliseconds.
    public var latencyMilliseconds: Int?
    /// One sentence for a person when `ok` is false.
    public var problem: String?

    public init(
        ok: Bool, adapter: PeerInfo? = nil, capabilities: Capabilities? = nil,
        latencyMilliseconds: Int? = nil, problem: String? = nil
    ) {
        self.ok = ok
        self.adapter = adapter
        self.capabilities = capabilities
        self.latencyMilliseconds = latencyMilliseconds
        self.problem = problem
    }

    enum CodingKeys: String, CodingKey {
        case ok, adapter, capabilities, latencyMilliseconds, problem
    }
}

/// The outcome of testing a binding's MCP server: its name and tools, or why it failed.
public struct BindingProbeReport: Sendable, Hashable, Codable {
    public var ok: Bool
    public var server: PeerInfo?
    public var tools: [String]
    /// Whether it serves the `history` convention (docs/PROTOCOL.md, "Binding conventions").
    public var servesHistory: Bool
    /// Round trip of `initialize`, in milliseconds.
    public var latencyMilliseconds: Int?
    public var problem: String?

    public init(
        ok: Bool, server: PeerInfo? = nil, tools: [String] = [], servesHistory: Bool = false,
        latencyMilliseconds: Int? = nil, problem: String? = nil
    ) {
        self.ok = ok
        self.server = server
        self.tools = tools
        self.servesHistory = servesHistory
        self.latencyMilliseconds = latencyMilliseconds
        self.problem = problem
    }

    enum CodingKeys: String, CodingKey {
        case ok, server, tools, servesHistory, latencyMilliseconds, problem
    }
}

/// Connection tests for the "test connection" step of setting up an adapter or a binding.
/// Each starts the command, talks to it briefly, ends it, and never throws: failures come back
/// as a report with a `problem` a person can act on.
public enum ConnectionProbe {
    /// The MCP protocol version arya offers a binding.
    public static let mcpProtocolVersion = "2025-06-18"

    /// Starts an adapter, sends `initialize` and `ping`, and shuts it down.
    public static func adapter(_ command: AdapterCommand, timeout: Duration = .seconds(10))
        async -> AdapterProbeReport
    {
        let stderr = StderrBuffer()
        let connection: AdapterConnection
        do {
            connection = try connect(command, stderr: stderr, timeout: timeout)
        } catch {
            return AdapterProbeReport(ok: false, problem: describe(error, command, stderr))
        }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let info = try await connection.initialize(
                InitializeParams(client: PeerInfo(name: "arya", version: "0.1.0")))
            let latency = milliseconds(clock.now - started)
            try await connection.ping()
            try? await connection.shutdown()
            return AdapterProbeReport(
                ok: true, adapter: info.adapter, capabilities: info.capabilities,
                latencyMilliseconds: latency)
        } catch {
            await connection.close()
            return AdapterProbeReport(ok: false, problem: describe(error, command, stderr))
        }
    }

    /// Starts a binding's MCP server, sends `initialize`, `tools/list`, and `ping`, and ends it.
    public static func binding(_ command: AdapterCommand, timeout: Duration = .seconds(10))
        async -> BindingProbeReport
    {
        let stderr = StderrBuffer()
        let connection: AdapterConnection
        do {
            connection = try connect(command, stderr: stderr, timeout: timeout)
        } catch {
            return BindingProbeReport(ok: false, problem: describe(error, command, stderr))
        }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let hello = try await connection.request(
                "initialize",
                params: [
                    "protocolVersion": .string(mcpProtocolVersion), "capabilities": [:],
                    "clientInfo": ["name": "arya", "version": "0.1.0"],
                ])
            let latency = milliseconds(clock.now - started)
            try await connection.notify("notifications/initialized")
            let listed = try await connection.request("tools/list")
            try await connection.ping()
            await connection.close()
            let tools = (listed["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            let server = hello["serverInfo"].flatMap { try? $0.decode(PeerInfo.self) }
            return BindingProbeReport(
                ok: true, server: server, tools: tools,
                servesHistory: tools.contains(BindingHistory.tool), latencyMilliseconds: latency)
        } catch {
            await connection.close()
            return BindingProbeReport(ok: false, problem: describe(error, command, stderr))
        }
    }

    private static func connect(
        _ command: AdapterCommand, stderr: StderrBuffer, timeout: Duration
    ) throws(AdapterError) -> AdapterConnection {
        let transport = try ProcessTransport.launch(command, stderr: stderr)
        let timeouts = ConnectionTimeouts(
            request: timeout, idle: nil, stopGrace: .seconds(2), killGrace: .seconds(2),
            exitGrace: .seconds(2))
        return AdapterConnection(transport: transport, timeouts: timeouts)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(
            duration.components.seconds * 1000 + duration.components.attoseconds
                / 1_000_000_000_000_000)
    }

    /// One sentence for a person, with the last stderr line when the process left one.
    static func describe(_ error: any Error, _ command: AdapterCommand, _ stderr: StderrBuffer)
        -> String
    {
        let name = URL(fileURLWithPath: command.executable).lastPathComponent
        let sentence: String
        switch error as? AdapterError {
        case .launchFailed(let detail):
            sentence = "Could not start \(name): \(detail)."
        case .exited(let exit):
            sentence = "\(name) exited before answering (\(exit))."
        case .requestTimedOut(let method):
            sentence = "\(name) did not answer \(method) in time."
        case .rpc(let rpc) where rpc.code == RPCErrorCode.unsupportedProtocol:
            sentence = "\(name) speaks a different protocol version: \(rpc.message)."
        case .rpc(let rpc):
            sentence = "\(name) refused the connection: \(rpc.message)."
        case .invalidResponse(let method, let detail):
            sentence = "\(name) answered \(method) with something unreadable: \(detail)."
        default:
            sentence = "\(name) could not be reached: \(error)."
        }
        let lastLine = String(decoding: stderr.contents, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)
        guard let lastLine, !lastLine.isEmpty else { return sentence }
        return "\(sentence) It said: \(lastLine.prefix(200))"
    }
}
