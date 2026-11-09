/// How an option takes its input.
enum OptionKind: Sendable, Equatable {
    /// A switch with no value: `--all`.
    case flag
    /// An option followed by a value: `--count 20` or `--count=20`.
    case value(placeholder: String)
}

/// One option a command accepts.
struct OptionSpec: Sendable, Equatable {
    /// The long name without dashes, also the lookup key.
    let name: String
    /// An optional one-letter alias: `-n`.
    var short: Character? = nil
    let kind: OptionKind
    /// Whether the command fails without it.
    var isRequired = false
    let help: String
}

/// One positional argument a command accepts, in order.
struct PositionalSpec: Sendable, Equatable {
    let name: String
    var isRequired = true
    let help: String
}

/// Options every command accepts.
struct GlobalOptions: Sendable, Equatable {
    /// `--home <dir>`: the arya home to use instead of `ARYA_HOME` or the default.
    var home: String?
    /// `--json`: machine-readable output.
    var isJSON = false
}

/// A fully parsed command line, ready to dispatch.
struct Invocation: Sendable, Equatable {
    let command: CommandID
    var positionals: [String: String] = [:]
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var global = GlobalOptions()

    /// The value of a required positional argument. Parsing guarantees it exists.
    func positional(_ name: String) throws(CLIError) -> String {
        guard let value = positionals[name] else {
            throw .usage("missing <\(name)>", command: command)
        }
        return value
    }

    /// The value of an integer option, or `fallback` when it is absent.
    func int(_ name: String, default fallback: Int) throws(CLIError) -> Int {
        guard let raw = values[name] else { return fallback }
        guard let value = Int(raw), value >= 0 else {
            throw .usage("--\(name) needs a non-negative integer, got \(raw)", command: command)
        }
        return value
    }
}

/// What the command line asks for.
enum ParseOutcome: Sendable, Equatable {
    case run(Invocation)
    /// Help for a command path; empty for the top level, a group for its subcommands.
    case help(path: [String], global: GlobalOptions)
    case version
}

/// Parses arguments against the command table without third-party dependencies.
struct ArgumentParser: Sendable {
    let commands: [CommandSpec]

    /// Parses `arguments` (without the program name).
    func parse(_ arguments: [String]) throws(CLIError) -> ParseOutcome {
        var global = GlobalOptions()
        var wantsHelp = false
        var wantsVersion = false
        let rest = try extractGlobals(
            arguments, into: &global, help: &wantsHelp, version: &wantsVersion)
        if wantsVersion { return .version }

        var words = rest.prefix { !$0.hasPrefix("-") }.map { $0 }
        if words.first == "help" {
            words.removeFirst()
            return .help(path: words, global: global)
        }
        if words.isEmpty, let first = rest.first, !wantsHelp {
            throw .usage("expected a command before \(first)")
        }
        guard let spec = longestMatch(words) else {
            if words.isEmpty || isGroup(words) || wantsHelp {
                if wantsHelp || words.isEmpty { return .help(path: words, global: global) }
                let subs = subcommands(of: words).joined(separator: ", ")
                throw .usage("\(words.joined(separator: " ")) needs a subcommand: \(subs)")
            }
            throw .usage("unknown command: \(words.joined(separator: " "))")
        }
        if wantsHelp { return .help(path: spec.path, global: global) }
        let tail = Array(rest.dropFirst(spec.path.count))
        var invocation = try parseTail(tail, spec: spec)
        invocation.global = global
        return .run(invocation)
    }

    /// Removes global options from anywhere before `--`, recording them.
    private func extractGlobals(
        _ arguments: [String], into global: inout GlobalOptions,
        help: inout Bool, version: inout Bool
    ) throws(CLIError) -> [String] {
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            switch arg {
            case "--":
                rest.append(contentsOf: arguments[(index - 1)...])
                return rest
            case "--json": global.isJSON = true
            case "-h", "--help": help = true
            case "--version": version = true
            case "--home":
                guard index < arguments.count else { throw .usage("--home needs a directory") }
                global.home = arguments[index]
                index += 1
            case _ where arg.hasPrefix("--home="):
                global.home = String(arg.dropFirst("--home=".count))
            default: rest.append(arg)
            }
        }
        return rest
    }

    private func longestMatch(_ words: [String]) -> CommandSpec? {
        commands
            .filter {
                $0.path.count <= words.count && Array(words.prefix($0.path.count)) == $0.path
            }
            .max { $0.path.count < $1.path.count }
    }

    /// Whether `words` names a command group such as `steward`.
    func isGroup(_ words: [String]) -> Bool {
        !words.isEmpty && !subcommands(of: words).isEmpty
    }

    /// The next path words under a group.
    func subcommands(of words: [String]) -> [String] {
        commands.compactMap { spec in
            spec.path.count > words.count && Array(spec.path.prefix(words.count)) == words
                ? spec.path[words.count] : nil
        }
    }

    /// Parses options and positionals after the command path.
    private func parseTail(_ tail: [String], spec: CommandSpec) throws(CLIError) -> Invocation {
        var invocation = Invocation(command: spec.id)
        var positionals: [String] = []
        var index = 0
        var optionsEnded = false
        while index < tail.count {
            let arg = tail[index]
            index += 1
            if optionsEnded || !arg.hasPrefix("-") || arg == "-" {
                positionals.append(arg)
                continue
            }
            if arg == "--" {
                optionsEnded = true
                continue
            }
            let (name, inline) = splitOption(arg)
            guard let option = spec.option(named: name) else {
                throw .usage("unknown option \(arg)", command: spec.id)
            }
            switch option.kind {
            case .flag:
                if inline != nil {
                    throw .usage("--\(option.name) takes no value", command: spec.id)
                }
                invocation.flags.insert(option.name)
            case .value(let placeholder):
                if let inline {
                    invocation.values[option.name] = inline
                } else if index < tail.count {
                    invocation.values[option.name] = tail[index]
                    index += 1
                } else {
                    throw .usage("--\(option.name) needs <\(placeholder)>", command: spec.id)
                }
            }
        }
        try assign(positionals, to: &invocation, spec: spec)
        for option in spec.options where option.isRequired && invocation.values[option.name] == nil
        {
            throw .usage("missing --\(option.name)", command: spec.id)
        }
        return invocation
    }

    private func splitOption(_ arg: String) -> (name: String, inline: String?) {
        if arg.hasPrefix("--") {
            let body = arg.dropFirst(2)
            if let eq = body.firstIndex(of: "=") {
                return (String(body[..<eq]), String(body[body.index(after: eq)...]))
            }
            return (String(body), nil)
        }
        return (String(arg.dropFirst()), nil)
    }

    private func assign(
        _ values: [String], to invocation: inout Invocation, spec: CommandSpec
    ) throws(CLIError) {
        if values.count > spec.positionals.count {
            let extra = values[spec.positionals.count]
            throw .usage("unexpected argument \(extra)", command: spec.id)
        }
        for (offset, positional) in spec.positionals.enumerated() {
            if offset < values.count {
                invocation.positionals[positional.name] = values[offset]
            } else if positional.isRequired {
                throw .usage("missing <\(positional.name)>", command: spec.id)
            }
        }
    }
}
