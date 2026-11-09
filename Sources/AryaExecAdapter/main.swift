import AryaAdapters
import Foundation

// `arya-exec-adapter --profile <name> --profiles <adapters.json>`: serves the adapter protocol
// on stdin and stdout by running the command-line agent an exec profile describes
// (docs/PROTOCOL.md, "Reference adapters").

/// Forwards the agent's stderr to this process's stderr, which arya captures.
struct ForwardStderr: StderrSink {
    func append(_ data: Data) { FileHandle.standardError.write(data) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("arya-exec-adapter: \(message)\n".utf8))
    exit(2)
}

let usage = "usage: arya-exec-adapter --profile <name> --profiles <adapters.json>"
var options: [String: String] = [:]
var rest = Array(CommandLine.arguments.dropFirst())
while rest.count >= 2, ["--profile", "--profiles"].contains(rest[0]) {
    options[rest[0]] = rest[1]
    rest.removeFirst(2)
}
guard rest.isEmpty, let name = options["--profile"], let file = options["--profiles"] else {
    fail(usage)
}
let profile: AdapterProfile
do {
    profile = try AdapterProfiles.load(from: URL(fileURLWithPath: file)).profile(name)
} catch {
    fail("\(error)")
}
// The entry point is the one place that reads the environment; the agent inherits it.
let server = ExecAdapterServer(
    profile: profile, environment: ProcessInfo.processInfo.environment,
    endpoint: StdioEndpoint(), agentStderr: ForwardStderr())
await server.serve()
exit(0)
