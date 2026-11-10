import AryaCore
import Foundation

/// The adapter side of `arya-exec-adapter`: runs one command-line agent per run from an exec
/// ``AdapterProfile`` and turns its output into `run/event` and `run/result`.
///
/// The agent runs in `run/start.workdir` with the prompt on stdin or as the last argument.
/// `jsonl` output streams events and cost totals as it arrives; `text` output is reported as
/// one `message` event when the agent exits. The result is checked against `resultSchema`; a
/// missing or non-matching result, or a non-zero exit, makes the run `failed`.
public actor ExecAdapterServer {
    private let profile: AdapterProfile
    private let environment: [String: String]
    private let endpoint: any AdapterEndpoint
    private let agentStderr: any StderrSink
    private let sandboxExec: String?

    private var session: String?
    private var request: RunStartParams?
    private var agent: ProcessTransport?
    private var events: [RunEvent] = []
    private var output: [String] = []
    private var outputBytes = 0
    private var mcpConfigFile: URL?
    private var denials: SandboxDenialWatcher?
    private var lastResult: JSONValue?
    private var cost = CostResult()
    private var finalText: String?
    private var agentReportedError = false
    private var lastReply: String?
    private var stopRequested = false
    private var resultSent = false
    private var closed = false

    /// How much agent output is kept for parsing: the last 8 MiB, where the result is.
    public static let maxOutputBytes = 8 << 20

    /// The MCP config file written into `workdir` for `mcpConfig: "file"` profiles.
    public static let mcpConfigFileName = ".arya-mcp.json"

    /// - Parameters:
    ///   - environment: the complete environment for the agent; profile `env` is added on top.
    ///   - agentStderr: where the agent's stderr goes (the binary forwards it to its own).
    ///   - sandboxExec: the `sandbox-exec` to launch sandboxed agents with, or `nil` when the
    ///     machine has none; the default finds the system one.
    public init(
        profile: AdapterProfile, environment: [String: String], endpoint: any AdapterEndpoint,
        agentStderr: any StderrSink = StderrBuffer(),
        sandboxExec: String? = OSSandbox.isAvailable ? OSSandbox.sandboxExecPath : nil
    ) {
        self.sandboxExec = sandboxExec
        self.profile = profile
        self.environment = environment.merging(profile.env) { _, profile in profile }
        self.endpoint = endpoint
        self.agentStderr = agentStderr
    }

    /// The capabilities this profile reports.
    public nonisolated var capabilities: Capabilities {
        Capabilities(
            effort: profile.supportedEfforts, send: false, cost: profile.parse != .text,
            transcript: true,
            tools: profile.mcpConfig == .file ? .mcp : .none,
            sandbox: sandboxExec == nil ? profile.sandbox : .os)
    }

    /// Serves until the host closes the connection or sends `shutdown`.
    public func serve() async {
        for await line in endpoint.incoming {
            if closed { break }
            await handle(line)
        }
        await close()
    }

    private func handle(_ line: Data) async {
        guard case .request(let request)? = try? LineCodec.decode(line) else { return }
        let outcome: Result<JSONValue, RPCError>
        do {
            outcome = .success(try await dispatch(request))
        } catch let error as RPCError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(RPCError(code: RPCErrorCode.invalidParams, message: "\(error)"))
        }
        await send(.response(RPCResponse(id: request.id, outcome: outcome)))
        if request.method == RPCMethod.runStart, case .success = outcome { await launchAgent() }
        if request.method == RPCMethod.shutdown { await close() }
    }

    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params ?? .object([:])
        switch request.method {
        case RPCMethod.initialize:
            let hello = try params.decode(InitializeParams.self)
            guard hello.protocolVersion == adapterProtocolVersion else {
                throw RPCError(
                    code: RPCErrorCode.unsupportedProtocol,
                    message: "unsupported protocol \(hello.protocolVersion)")
            }
            let adapter = PeerInfo(name: "exec", version: "0.1.0")
            return try JSONValue(
                encoding: InitializeResult(adapter: adapter, capabilities: capabilities))
        case RPCMethod.runStart:
            return try start(params)
        case RPCMethod.runStop:
            try checkSession(try params.decode(RunStopParams.self).session)
            await stopAgent()
            return .object([:])
        case RPCMethod.runTranscript:
            try checkSession(try params.decode(SessionParams.self).session)
            return try JSONValue(encoding: TranscriptResult(events: events))
        case RPCMethod.runCost:
            try checkSession(try params.decode(SessionParams.self).session)
            return try JSONValue(encoding: cost)
        case RPCMethod.runSend:
            throw RPCError(code: RPCErrorCode.capabilityNotSupported, message: "send unsupported")
        case RPCMethod.shutdown, RPCMethod.ping:
            return .object([:])
        default:
            throw RPCError(
                code: RPCErrorCode.methodNotFound, message: "unknown method \(request.method)")
        }
    }

    private func start(_ params: JSONValue) throws -> JSONValue {
        guard session == nil else {
            throw RPCError(code: RPCErrorCode.busy, message: "busy: this process already has a run")
        }
        let start = try params.decode(RunStartParams.self)
        if start.sandbox != nil, sandboxExec == nil {
            throw RPCError(
                code: RPCErrorCode.capabilityNotSupported,
                message: "no OS sandbox on this machine")
        }
        session = "exec-\(start.run)"
        request = start
        return try JSONValue(encoding: RunStartResult(session: session ?? ""))
    }

    private func checkSession(_ id: String) throws {
        guard let session, id == session else {
            throw RPCError(code: RPCErrorCode.unknownSession, message: "unknown session \(id)")
        }
    }

    // MARK: The agent

    private func launchAgent() async {
        guard let request else { return }
        let prompt = ExecPrompt.compose(request, parse: profile.parse)
        do {
            var arguments = profile.arguments(for: request.effort)
            if profile.mcpConfig == .file {
                let path = try writeMCPConfig(request)
                arguments = arguments.map { $0.replacingOccurrences(of: "{mcpConfig}", with: path) }
            }
            if profile.promptVia == .argument { arguments.append(prompt) }
            var command = AdapterCommand(
                executable: profile.command, arguments: arguments, environment: environment,
                workingDirectory: request.workdir)
            if let sandbox = request.sandbox, let sandboxExec {
                // Temporary files go inside the workdir, which the sandbox lets the agent write.
                let tmp = URL(fileURLWithPath: request.workdir).appendingPathComponent(".tmp")
                try FileManager.default.createDirectory(
                    at: tmp, withIntermediateDirectories: true)
                command.environment["TMPDIR"] = tmp.path
                command = OSSandbox.wrap(command, in: sandbox, sandboxExec: sandboxExec)
            }
            var stderr = agentStderr
            if request.sandbox != nil {
                let watcher = SandboxDenialWatcher(forwardingTo: agentStderr)
                denials = watcher
                stderr = watcher
            }
            let agent = try ProcessTransport.launch(command, stderr: stderr)
            self.agent = agent
            await emit(RunEvent(.status(state: "working", detail: "agent started")))
            Task { await self.read(agent) }
            // The write is queued, so an agent that does not read stdin cannot block `run/stop`.
            if profile.promptVia == .stdin { try? await agent.write(Data(prompt.utf8)) }
            await agent.closeInput()
        } catch {
            await emit(RunEvent(.error(message: "cannot start the agent: \(error)")))
            await finish(.failed, result: nil)
        }
    }

    private func writeMCPConfig(_ request: RunStartParams) throws -> String {
        var servers: [String: JSONValue] = [:]
        for tool in request.tools {
            servers[tool.name] = [
                "command": .string(tool.command), "args": .array(tool.args.map { .string($0) }),
            ]
        }
        let config: JSONValue = ["mcpServers": .object(servers)]
        let url = URL(fileURLWithPath: request.workdir)
            .appendingPathComponent(Self.mcpConfigFileName)
        try LineCodec.encodeJSON(config).write(to: url)
        mcpConfigFile = url
        return url.path
    }

    private func read(_ agent: ProcessTransport) async {
        for await input in agent.input {
            switch input {
            case .line(let data):
                await consume(String(decoding: data, as: UTF8.self))
            case .ended(let exit):
                await agentEnded(exit)
            }
        }
    }

    private func consume(_ line: String) async {
        output.append(line)
        outputBytes += line.utf8.count + 1
        var dropped = 0
        while outputBytes > Self.maxOutputBytes, dropped < output.count - 1 {
            outputBytes -= output[dropped].utf8.count + 1
            dropped += 1
        }
        if dropped > 0 { output.removeFirst(dropped) }
        switch profile.parse {
        case .text:
            break
        case .jsonl:
            switch ExecOutput.parse(jsonLine: line) {
            case .result(let value): lastResult = value
            case .event(let event): await emit(event)
            case .cost(let totals): cost = totals
            case .other: break
            }
        case .streamJSON:
            switch ExecOutput.parse(streamJSONLine: line) {
            case .events(let events):
                for event in events { await emit(event) }
            case .final(let text, let isError, let totals):
                finalText = text
                agentReportedError = isError
                cost = totals
            case .other:
                break
            }
        case .codexJSON:
            switch ExecOutput.parse(codexJSONLine: line) {
            case .events(let events, let reply):
                for event in events { await emit(event) }
                if let reply { lastReply = reply }
            case .usage(let turn):
                cost = CostResult(
                    inputTokens: cost.inputTokens + turn.inputTokens,
                    outputTokens: cost.outputTokens + turn.outputTokens, costMicros: 0)
            case .failed(let message):
                agentReportedError = true
                await emit(RunEvent(.error(message: message)))
            case .other:
                break
            }
        }
    }

    private func agentEnded(_ exit: AdapterExit) async {
        // The agent's stderr is drained before its end is reported, so a denial is known now.
        if let report = denials?.report { await emit(RunEvent(.error(message: report))) }
        if stopRequested {
            await finish(.stopped, result: nil)
            return
        }
        var result = lastResult
        switch profile.parse {
        case .text:
            let text = output.joined(separator: "\n")
            if !text.isEmpty { await emit(RunEvent(.message(role: "assistant", text: text))) }
            result = ExecOutput.lastJSONBlock(in: text)
        case .streamJSON:
            result = finalText.flatMap(ExecOutput.lastJSONBlock(in:))
        case .codexJSON:
            result = lastReply.flatMap(ExecOutput.lastJSONBlock(in:))
        case .jsonl:
            break
        }
        guard let result else {
            await emit(RunEvent(.error(message: "the agent \(exit) without a result")))
            await finish(.failed, result: nil)
            return
        }
        if let schema = request?.resultSchema,
            let problem = ResultSchema.violation(of: schema, by: result)
        {
            await emit(RunEvent(.error(message: "result does not match resultSchema: \(problem)")))
            await finish(.failed, result: result)
            return
        }
        if !exit.isClean || agentReportedError {
            let reason = agentReportedError ? "reported an error" : "\(exit)"
            await emit(RunEvent(.error(message: "the agent \(reason)")))
            await finish(.failed, result: result)
            return
        }
        await finish(.completed, result: result)
    }

    private func stopAgent() async {
        guard !resultSent else { return }
        stopRequested = true
        guard let agent else {
            await finish(.stopped, result: nil)
            return
        }
        Task { await agent.terminate(grace: .seconds(5)) }
    }

    // MARK: Output

    private func emit(_ event: RunEvent) async {
        guard let session, !resultSent else { return }
        events.append(event)
        await notify(
            RPCMethod.runEvent, RunEventParams(session: session, seq: events.count, event: event))
    }

    private func finish(_ status: RunStatus, result: JSONValue?) async {
        guard !resultSent, let session else { return }
        resultSent = true
        // The config names arya's tool commands only; remove it so workdir holds run output.
        if let file = mcpConfigFile { try? FileManager.default.removeItem(at: file) }
        await notify(
            RPCMethod.runResult, RunResultParams(session: session, status: status, result: result))
    }

    private func notify(_ method: String, _ params: some Encodable) async {
        guard let value = try? JSONValue(encoding: params) else { return }
        await send(.notification(RPCNotification(method: method, params: value)))
    }

    private func send(_ message: RPCMessage) async {
        guard !closed else { return }
        await endpoint.write(LineCodec.encode(message))
    }

    private func close() async {
        guard !closed else { return }
        closed = true
        if let agent { await agent.terminate(grace: .seconds(1)) }
        await endpoint.close(.exited(0))
    }
}

/// The prompt an exec profile gives its agent.
public enum ExecPrompt {
    /// Instructions, the input, any attachments, and how to report the result.
    public static func compose(_ request: RunStartParams, parse: OutputParser) -> String {
        var parts = [
            request.instructions, "Input (\(request.input.kind.rawValue)):\n\(request.input.text)",
        ]
        if !request.input.attachments.isEmpty {
            let attachments = String(
                decoding: LineCodec.encodeJSON(.array(request.input.attachments)), as: UTF8.self)
            parts.append("Attachments (JSON):\n\(attachments)")
        }
        let schema =
            request.resultSchema.map {
                " It must match this JSON Schema:\n"
                    + String(decoding: LineCodec.encodeJSON($0), as: UTF8.self)
            } ?? ""
        switch parse {
        case .text, .streamJSON, .codexJSON:
            parts.append(
                "When you are done, reply with the result as one JSON object in a fenced json"
                    + " code block. The last such block is read as the result." + schema)
        case .jsonl:
            parts.append(
                "Print one JSON object per line. When you are done, print the result as"
                    + " {\"result\": {...}}. The last such line is read as the result." + schema)
        }
        return parts.joined(separator: "\n\n")
    }
}
