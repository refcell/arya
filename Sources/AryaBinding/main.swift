import AryaAdapters
import Foundation

// `arya-binding`: zero-dependency MCP binding servers for real local systems
// (docs/PROTOCOL.md, "Local connectors").
//
//   arya-binding folder <directory>
//   arya-binding http-json --base-url <url> [--actions kind,kind…]
//
// The http-json token comes from the ARYA_CREDENTIAL environment variable, which arya fills
// from the connection's Keychain entry; it is never a command-line argument.

let usage = """
    usage: arya-binding folder <directory>
           arya-binding http-json --base-url <url> [--actions kind,kind…]

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("arya-binding: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
arguments.removeFirst()

let source: any BindingSource
switch mode {
case "folder":
    guard arguments.count == 1 else { fail("folder takes one directory") }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: arguments[0], isDirectory: &isDirectory),
        isDirectory.boolValue
    else { fail("\(arguments[0]) is not a directory") }
    source = FolderBindingSource(directory: URL(fileURLWithPath: arguments[0]))
case "http-json":
    var baseURL: URL?
    var actions: [String] = []
    while let flag = arguments.first {
        arguments.removeFirst()
        guard let value = arguments.first else { fail("\(flag) needs a value") }
        arguments.removeFirst()
        switch flag {
        case "--base-url": baseURL = URL(string: value)
        case "--actions": actions = value.split(separator: ",").map(String.init)
        default: fail("unknown option \(flag)")
        }
    }
    guard let baseURL else { fail("http-json needs --base-url") }
    let token = ProcessInfo.processInfo.environment[BindingCredential.variable]
    let config = HTTPJSONConfig(baseURL: baseURL, token: token, actions: actions)
    if let problem = config.problem { fail(problem) }
    source = HTTPJSONBindingSource(config: config)
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
await BindingServer(source: source).serve(StdioEndpoint())
exit(0)
