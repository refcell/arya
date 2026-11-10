import AryaAdapters
import Foundation

// `arya-fake-adapter --script <file>`: serves the adapter protocol on stdin and stdout from a
// fake adapter script (docs/PROTOCOL.md, "Fake adapter scripts").
// `arya-fake-adapter --binding <file>`: serves a fake MCP binding with the `history`, `get`,
// and `search` tools from a records file (docs/PROTOCOL.md, "Binding conventions").

let usage = "usage: arya-fake-adapter --script <file> | --binding <file>\n"
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, ["--script", "--binding"].contains(arguments[0]) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let file = URL(fileURLWithPath: arguments[1])
let endpoint = StdioEndpoint()
if arguments[0] == "--binding" {
    let data: FakeBindingData
    do {
        data = try FakeBindingData.load(from: file)
    } catch {
        FileHandle.standardError.write(
            Data("arya-fake-adapter: cannot read binding records: \(error)\n".utf8))
        exit(2)
    }
    await FakeBindingServer(data: data).serve(endpoint)
    exit(0)
}
let script: FakeScript
do {
    script = try FakeScript.load(from: file)
} catch {
    FileHandle.standardError.write(Data("arya-fake-adapter: cannot read script: \(error)\n".utf8))
    exit(2)
}
// `ARYA_FAKE_PACE_MS` paces the run like live work (demo pace, decision 0051).
let pace = ProcessInfo.processInfo.environment["ARYA_FAKE_PACE_MS"].flatMap { Int($0) } ?? 0
await FakeAdapterServer(script: script, endpoint: endpoint, pace: pace).serve()
exit(0)
