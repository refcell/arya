import AryaAdapters
import Foundation

// `arya-fake-adapter --script <file>`: serves the adapter protocol on stdin and stdout from a
// fake adapter script (docs/PROTOCOL.md, "Fake adapter scripts").

let usage = "usage: arya-fake-adapter --script <file>\n"
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--script" else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let script: FakeScript
do {
    script = try FakeScript.load(from: URL(fileURLWithPath: arguments[1]))
} catch {
    FileHandle.standardError.write(Data("arya-fake-adapter: cannot read script: \(error)\n".utf8))
    exit(2)
}
let endpoint = StdioEndpoint()
await FakeAdapterServer(script: script, endpoint: endpoint).serve()
exit(0)
