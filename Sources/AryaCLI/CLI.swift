import Foundation

/// The `arya` command: parses arguments, opens the backend for the home, runs one command.
enum CLI {
    static let version = "0.1.0"

    /// What the entry point reads from the process, passed in so tests stay deterministic.
    struct Context: Sendable {
        var environment: [String: String]
        /// The user's home directory, for the default arya home.
        var userHome: URL
        /// The working directory, for relative `--home` paths.
        var workingDirectory: URL
    }

    /// Runs one command line (without the program name) and returns the exit status.
    static func run(
        _ arguments: [String], context: Context, output: Output, backend makeBackend: BackendFactory
    ) async -> ExitStatus {
        let parser = ArgumentParser(commands: CommandTable.all)
        do {
            switch try parser.parse(arguments) {
            case .version:
                output.write("arya \(version)")
            case .help(let path, _):
                try output.writeLines(Help.text(for: path, parser: parser))
            case .run(let invocation):
                let home = Home.resolve(
                    flag: invocation.global.home, environment: context.environment,
                    userHome: context.userHome, workingDirectory: context.workingDirectory)
                try await dispatch(invocation, backend: makeBackend(home), output: output)
            }
            return .ok
        } catch {
            report(error, output: output)
            return error.status
        }
    }

    private static func report(_ error: CLIError, output: Output) {
        output.writeError("arya: \(error.message)")
        if case .usage(_, let command) = error {
            if let command {
                output.writeError("usage: \(CommandTable.spec(command).usage)")
            }
            output.writeError("run `arya --help` for the list of commands")
        }
    }

    private static func dispatch(
        _ invocation: Invocation, backend: any CLIBackend, output: Output
    ) async throws(CLIError) {
        let json = invocation.global.isJSON
        switch invocation.command {
        case .initHome:
            try output.emit(await backend.initHome(), json: json, text: TextRender.initReport)
        case .stewardCreate:
            let charter = invocation.values["charter"] ?? ""
            try output.emit(
                await backend.createSteward(charterPath: charter), json: json,
                text: TextRender.steward)
        case .stewardList:
            try output.emit(await backend.listStewards(), json: json, text: TextRender.stewards)
        case .stewardShow:
            let id = try invocation.positional("steward")
            try output.emit(await backend.showSteward(id), json: json, text: TextRender.steward)
        case .stewardPause:
            let id = try invocation.positional("steward")
            try output.emit(await backend.pauseSteward(id), json: json, text: TextRender.steward)
        case .stewardResume:
            let id = try invocation.positional("steward")
            try output.emit(await backend.resumeSteward(id), json: json, text: TextRender.steward)
        case .run:
            let report = try await backend.startRun(
                steward: try invocation.positional("steward"), input: invocation.values["input"])
            try output.emit(report, json: json, text: TextRender.run)
            if report.status != "completed" { throw .failed("run \(report.run) \(report.status)") }
        case .runShow:
            let report = try await backend.showRun(try invocation.positional("run"))
            try output.emit(report, json: json, text: TextRender.run)
        case .approvals:
            let scope: ApprovalScope = invocation.flags.contains("all") ? .all : .pending
            let approvals = try await backend.listApprovals(
                steward: invocation.values["steward"], scope: scope)
            try output.emit(approvals, json: json, text: TextRender.approvals)
        case .approve, .deny:
            let decision: ApprovalDecision = invocation.command == .approve ? .grant : .deny
            let result = try await backend.decide(
                approval: try invocation.positional("approval"), decision: decision,
                note: invocation.values["note"])
            try output.emit(result, json: json, text: TextRender.decision)
        case .ledgerTail:
            let events = try await backend.tailLedger(
                count: try invocation.int("count", default: 20),
                steward: invocation.values["steward"])
            try output.emit(events, json: json, text: TextRender.events)
        case .ledgerVerify:
            let report = try await backend.verifyLedger()
            try output.emit(report, json: json, text: TextRender.verify)
            if !report.isValid { throw .failed("ledger verification failed") }
        case .casebookImport, .casebookList, .rehearse, .correct, .runCorrect, .retract, .ready,
            .propose, .proposals, .readiness,
            .metrics, .memory, .routines, .replay, .bindingProxy:
            try await dispatchImprovement(invocation, backend: backend, output: output)
        case .historyImport, .review:
            try await dispatchHistory(invocation, backend: backend, output: output)
        case .serve:
            try await backend.serve(every: try Self.every(invocation))
        case .serveInstall:
            let report = try await backend.installLoginItem(every: try Self.every(invocation))
            try output.emit(report, json: json, text: TextRender.loginItem)
        case .serveUninstall:
            try output.emit(
                try await backend.uninstallLoginItem(), json: json, text: TextRender.loginItem)
        }
    }

    /// `--every <seconds>`: a positive whole number, 60 by default.
    static func every(_ invocation: Invocation) throws(CLIError) -> Int {
        guard let text = invocation.values["every"] else { return 60 }
        guard let seconds = Int(text), seconds > 0 else {
            throw .usage("--every needs a positive number of seconds, got \(text)")
        }
        return seconds
    }
}

extension Output {
    /// Writes `value` as JSON or as the lines `text` renders.
    func emit<T: Encodable>(_ value: T, json: Bool, text: (T) -> [String]) throws(CLIError) {
        if json { try self.json(value) } else { writeLines(text(value)) }
    }

    func writeLines(_ lines: [String]) {
        for line in lines { write(line) }
    }
}

/// Resolves the arya home: `--home`, then `ARYA_HOME`, then the per-user default.
enum Home {
    static func resolve(
        flag: String?, environment: [String: String], userHome: URL, workingDirectory: URL
    ) -> URL {
        if let path = flag ?? environment["ARYA_HOME"].flatMap({ $0.isEmpty ? nil : $0 }) {
            return url(for: path, userHome: userHome, workingDirectory: workingDirectory)
        }
        return
            userHome
            .appendingPathComponent("Library/Application Support/arya", isDirectory: true)
    }

    private static func url(for path: String, userHome: URL, workingDirectory: URL) -> URL {
        if path == "~" { return userHome }
        if path.hasPrefix("~/") {
            return userHome.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                .standardizedFileURL
        }
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: workingDirectory)
            .standardizedFileURL
    }
}

/// Help text for the top level, a command group, or one command.
enum Help {
    static func text(for path: [String], parser: ArgumentParser) throws(CLIError) -> [String] {
        if path.isEmpty { return topLevel(parser.commands) }
        if let spec = parser.commands.first(where: { $0.path == path }) { return command(spec) }
        guard parser.isGroup(path) else {
            throw .usage("unknown command: \(path.joined(separator: " "))")
        }
        let specs = parser.commands.filter { Array($0.path.prefix(path.count)) == path }
        return ["usage: arya \(path.joined(separator: " ")) <command>", ""] + rows(specs)
    }

    static func topLevel(_ commands: [CommandSpec]) -> [String] {
        [
            "arya \(CLI.version): persistent agents that own an outcome", "",
            "usage: arya [--home <dir>] [--json] <command> [<args>]", "", "commands:",
        ] + rows(commands) + [
            "", "global options:",
            "  --home <dir>  arya home (default: $ARYA_HOME, then the per-user default)",
            "  --json        machine-readable output",
            "  -h, --help    show help; `arya <command> --help` for one command",
            "  --version     print the version",
        ]
    }

    static func command(_ spec: CommandSpec) -> [String] {
        var lines = ["usage: \(spec.usage)", "", spec.summary]
        var table = Table(headers: ["", ""])
        for positional in spec.positionals {
            table.rows.append(["  <\(positional.name)>", positional.help])
        }
        for option in spec.options {
            let short = option.short.map { "-\($0), " } ?? ""
            switch option.kind {
            case .flag: table.rows.append(["  \(short)--\(option.name)", option.help])
            case .value(let placeholder):
                table.rows.append(["  \(short)--\(option.name) <\(placeholder)>", option.help])
            }
        }
        if !table.rows.isEmpty { lines += [""] + table.lines.dropFirst() }
        return lines
    }

    private static func rows(_ specs: [CommandSpec]) -> [String] {
        var table = Table(headers: ["", ""])
        for spec in specs {
            table.rows.append(["  " + spec.path.joined(separator: " "), spec.summary])
        }
        return Array(table.lines.dropFirst())
    }
}
