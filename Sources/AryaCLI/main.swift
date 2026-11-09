import Foundation

// `arya` command-line entry point. The process environment, home directory, and working
// directory are read here, once, and passed down; library code never reads them.
let context = CLI.Context(
    environment: ProcessInfo.processInfo.environment,
    userHome: FileManager.default.homeDirectoryForCurrentUser,
    workingDirectory: URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
let status = await CLI.run(
    Array(CommandLine.arguments.dropFirst()), context: context, output: .standard,
    backend: { PendingBackend(home: $0) })
exit(status.rawValue)
