import Foundation

// `arya` command-line entry point. The process environment, home directory, and working
// directory are read here, once, and passed down; library code never reads them.
let context = CLI.Context(
    environment: ProcessInfo.processInfo.environment,
    userHome: FileManager.default.homeDirectoryForCurrentUser,
    workingDirectory: URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
// `ARYA_CLOCK=<RFC 3339 time>` stamps events from that time; `just demo` seeds past history.
let clock: Date? = {
    guard let text = context.environment["ARYA_CLOCK"], !text.isEmpty else { return nil }
    guard let parsed = WorkspaceBackend.clock(text) else {
        FileHandle.standardError.write(
            Data("arya: ARYA_CLOCK is not an RFC 3339 time: \(text)\n".utf8))
        exit(ExitStatus.usage.rawValue)
    }
    return parsed
}()
let status = await CLI.run(
    Array(CommandLine.arguments.dropFirst()), context: context, output: .standard,
    backend: { WorkspaceBackend(home: $0, clock: clock) })
exit(status.rawValue)
