import AryaAdapters
import AryaCore
import AryaLedger
import Foundation

/// How the runtime launches a binding proxy for a harness: a command (for example the `arya`
/// executable) and leading arguments (for example `binding-proxy --home <home>`). The runtime
/// appends `--steward <id> --run <id> --binding <id>` and, in rehearsal, `--recorded <file>`.
public struct BindingProxyLaunch: Sendable, Hashable {
    /// The executable.
    public var command: String
    /// Leading arguments.
    public var args: [String]

    /// Creates a launch description.
    public init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }

    /// The tool servers a run of `charter` hands its adapter: one per MCP binding with read
    /// tools.
    /// With `sandbox`, each proxy confines its live server to that workdir.
    func servers(charter: Charter, run: RunID, recorded: String?, sandbox: String? = nil)
        -> [ToolServer]
    {
        charter.bindings.filter { $0.kind == .mcp && !$0.read.isEmpty }.map { binding in
            var tail = [
                "--steward", charter.id.rawValue, "--run", run.rawValue, "--binding", binding.id,
            ]
            if let recorded { tail += ["--recorded", recorded] }
            if let sandbox { tail += ["--sandbox", sandbox] }
            return ToolServer(name: binding.id, command: command, args: args + tail)
        }
    }
}

/// The arguments of one binding-proxy process.
public struct BindingProxyArguments: Sendable, Hashable {
    /// The run's steward.
    public var steward: StewardID
    /// The run.
    public var run: RunID
    /// The binding id.
    public var binding: String
    /// A JSON file of `RecordedToolResult`s to answer from instead of the live server.
    public var recorded: String?
    /// The run workdir to sandbox the live server in.
    public var sandbox: String?

    /// Parses `--steward <id> --run <id> --binding <id> [--recorded <file>]
    /// [--sandbox <workdir>]`.
    public init(parsing arguments: [String]) throws {
        var values: [String: String] = [:]
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard ["--steward", "--run", "--binding", "--recorded", "--sandbox"].contains(flag),
                let value = rest.popFirst()
            else { throw BindingProxyError.badArguments("unexpected \(flag)") }
            values[flag] = value
        }
        guard let steward = values["--steward"], let run = values["--run"],
            let binding = values["--binding"]
        else { throw BindingProxyError.badArguments("needs --steward, --run, and --binding") }
        self.steward = StewardID(unchecked: steward)
        self.run = RunID(unchecked: run)
        self.binding = binding
        recorded = values["--recorded"]
        sandbox = values["--sandbox"]
    }
}

/// Why a binding proxy could not start.
public enum BindingProxyError: Error, Equatable, Sendable {
    /// The command line is wrong.
    case badArguments(String)
    /// The steward is not in the ledger.
    case unknownSteward(StewardID)
    /// The steward's live charter has no MCP binding with that id.
    case unknownBinding(String)
}

/// Runs one binding proxy process: finds the binding in the steward's live charter, answers
/// from the recordings file or the live server, and serves MCP on stdin and stdout until stdin
/// closes.
public enum BindingProxyHost {
    /// The proxy for `arguments`, recording into `sink`. Live proxies start the server process.
    public static func proxy(_ arguments: BindingProxyArguments, sink: any EventSink)
        async throws -> BindingProxy
    {
        let record = try await StewardLifecycle(sink: sink).book().records[arguments.steward]
        guard let record else { throw BindingProxyError.unknownSteward(arguments.steward) }
        guard let binding = record.charter.binding(arguments.binding), binding.kind == .mcp,
            let command = binding.command
        else { throw BindingProxyError.unknownBinding(arguments.binding) }
        let source: ToolSource
        if let path = arguments.recorded {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            source = .recorded(try CanonicalJSON.decode([RecordedToolResult].self, from: data))
        } else {
            let sandbox = try arguments.sandbox.map {
                try Sandbox(workdir: $0, network: binding.network)
            }
            source = .live(try BindingActionExecutor.spawn(binding, sandbox: sandbox))
        }
        return BindingProxy(
            binding: binding, source: source,
            recorder: ToolCallRecorder(sink: sink, steward: arguments.steward, run: arguments.run))
    }

    /// Serves `proxy` on stdin and stdout until stdin closes.
    public static func serveStandardIO(_ proxy: BindingProxy) async {
        let (input, feed) = AsyncStream<Data>.makeStream()
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        await proxy.serve(input) { try? FileHandle.standardOutput.write(contentsOf: $0) }
    }
}

/// Recorded tool results from the ledger, for replaying a run.
public enum ToolRecordings {
    /// Each `run.tool.call` of `run` paired with its `run.tool.result`, in call order, with the
    /// tool named `<binding>.<tool>`. Calls without a result are skipped.
    public static func from(_ events: [RuntimeEvent], run: RunID) throws -> [RecordedToolResult] {
        var calls: [(id: String, call: RunToolCall)] = []
        var results: [String: RunToolResult] = [:]
        for event in events where event.draft.run == run {
            switch event.type {
            case RunToolCall.type.rawValue:
                let call = try Payload.decode(RunToolCall.self, event.payload)
                calls.append((call.id, call))
            case RunToolResult.type.rawValue:
                let result = try Payload.decode(RunToolResult.self, event.payload)
                results[result.id] = result
            default:
                continue
            }
        }
        return calls.compactMap { id, call in
            results[id].map {
                RecordedToolResult(
                    tool: "\(call.binding).\(call.tool)", input: call.input, output: $0.output,
                    isError: $0.isError)
            }
        }
    }
}
