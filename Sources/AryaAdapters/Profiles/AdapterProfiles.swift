import AryaCore
import Foundation

/// `adapters.json`: named adapter profiles. A charter names a profile in `adapter` and an
/// effort; the profile turns them into a command line, so charters never name models.
///
/// A profile is one of two kinds. An `adapter` profile's command speaks the adapter protocol
/// itself (`arya-fake-adapter`, a third-party adapter). An `exec` profile's command is a
/// command-line agent that `arya-exec-adapter` wraps; it adds how the prompt is passed, how
/// output is parsed, and how MCP tools are handed over.
public struct AdapterProfiles: Sendable, Hashable, Codable {
    public var v: Int
    public var profiles: [String: AdapterProfile]

    public init(profiles: [String: AdapterProfile] = [:]) {
        self.v = 1
        self.profiles = profiles
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        guard v == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .v, in: c, debugDescription: "unsupported adapters.json version \(v)")
        }
        profiles = try c.decodeIfPresent([String: AdapterProfile].self, forKey: .profiles) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case v, profiles
    }

    /// Decodes and validates `adapters.json` bytes.
    public static func decode(_ data: Data) throws(AdapterProfileError) -> AdapterProfiles {
        let book: AdapterProfiles
        do {
            book = try CanonicalJSON.decode(AdapterProfiles.self, from: data)
        } catch {
            throw .invalid(name: nil, detail: "\(error)")
        }
        try book.validate()
        return book
    }

    /// Reads `adapters.json`; a missing file is an empty set of profiles.
    public static func load(from url: URL) throws(AdapterProfileError) -> AdapterProfiles {
        guard FileManager.default.fileExists(atPath: url.path) else { return AdapterProfiles() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .invalid(name: nil, detail: "cannot read \(url.lastPathComponent): \(error)")
        }
        return try decode(data)
    }

    /// The profile named `name`.
    public func profile(_ name: String) throws(AdapterProfileError) -> AdapterProfile {
        guard let profile = profiles[name] else { throw .unknownProfile(name) }
        return profile
    }

    /// Checks every profile; the first problem is thrown.
    public func validate() throws(AdapterProfileError) {
        for name in profiles.keys.sorted() {
            if let problem = profiles[name]?.problem {
                throw .invalid(name: name, detail: problem)
            }
        }
    }
}

/// Problems with `adapters.json` or a lookup in it.
public enum AdapterProfileError: Error, Sendable, Hashable, CustomStringConvertible {
    case unknownProfile(String)
    case invalid(name: String?, detail: String)

    public var description: String {
        switch self {
        case .unknownProfile(let name): "no adapter profile named \(name)"
        case .invalid(let name?, let detail): "adapter profile \(name): \(detail)"
        case .invalid(nil, let detail): "adapters.json: \(detail)"
        }
    }
}

/// What a profile's command is.
public enum AdapterProfileKind: String, Sendable, Hashable, Codable {
    /// The command speaks the adapter protocol.
    case adapter
    /// The command is a command-line agent wrapped by `arya-exec-adapter`.
    case exec
}

/// How `arya-exec-adapter` passes the prompt to the agent.
public enum PromptDelivery: String, Sendable, Hashable, Codable {
    /// Written to the agent's stdin, which is then closed.
    case stdin
    /// Appended as the last argument.
    case argument
}

/// How `arya-exec-adapter` reads the agent's output.
public enum OutputParser: String, Sendable, Hashable, Codable {
    /// Plain text; the last fenced `json` block is the result.
    case text
    /// One JSON object per line; the last object with a `result` key is the result.
    case jsonl
    /// Claude Code's `--output-format stream-json`: messages become run events, and the final
    /// `result` line gives the result (its last fenced `json` block), the cost, and failure.
    case streamJSON = "stream-json"
    /// Codex CLI's `exec --json`: completed items become run events, the last agent message
    /// gives the result (its last fenced `json` block), and turn usage gives token counts.
    case codexJSON = "codex-json"
    /// The input is a shell command, not a prompt: its stdout and stderr stream as
    /// `tool_output` of one `shell` call, its exit status ends the call, and a
    /// `{"result": {...}}` line, if printed, is the result (else a summary of the exit).
    case command
}

/// How `arya-exec-adapter` hands `run/start.tools` to the agent.
public enum MCPConfigDelivery: String, Sendable, Hashable, Codable {
    /// Tools are not passed; the profile reports capability `tools: "none"`.
    case none
    /// An MCP config file is written into `workdir`; its path replaces `{mcpConfig}` in args.
    case file
}

/// One named profile in `adapters.json`.
public struct AdapterProfile: Sendable, Hashable, Codable {
    public var kind: AdapterProfileKind
    /// A path or a name looked up on `PATH`.
    public var command: String
    /// Arguments per effort (`low`, `medium`, `high`).
    public var args: [String: [String]]
    /// Variables added to the environment the caller passes.
    public var env: [String: String]
    /// Exec profiles: how the prompt is passed (default `stdin`).
    public var promptVia: PromptDelivery
    /// Exec profiles: how output is parsed (default `text`).
    public var parse: OutputParser
    /// Exec profiles: how MCP tools are passed (default `none`).
    public var mcpConfig: MCPConfigDelivery
    /// Exec profiles: whether the agent's built-in write tools are confined to `workdir` or
    /// off with these arguments, reported as capability `sandbox` (default `none`).
    public var sandbox: SandboxSupport
    /// A name people read ("Scripted triage (demo)"); the app shows the profile id when nil.
    public var label: String? = nil

    public static let efforts = ["low", "medium", "high"]

    public init(
        kind: AdapterProfileKind = .adapter, command: String, args: [String: [String]] = [:],
        env: [String: String] = [:], promptVia: PromptDelivery = .stdin,
        parse: OutputParser = .text, mcpConfig: MCPConfigDelivery = .none,
        sandbox: SandboxSupport = .none
    ) {
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.promptVia = promptVia
        self.parse = parse
        self.mcpConfig = mcpConfig
        self.sandbox = sandbox
    }

    /// A missing `kind` is `exec` when any exec-only field is present, else `adapter`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let execOnly: [CodingKeys] = [.promptVia, .parse, .mcpConfig, .sandbox]
        let derived: AdapterProfileKind = execOnly.contains(where: c.contains) ? .exec : .adapter
        kind = try c.decodeIfPresent(AdapterProfileKind.self, forKey: .kind) ?? derived
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String: [String]].self, forKey: .args) ?? [:]
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        promptVia = try c.decodeIfPresent(PromptDelivery.self, forKey: .promptVia) ?? .stdin
        parse = try c.decodeIfPresent(OutputParser.self, forKey: .parse) ?? .text
        mcpConfig = try c.decodeIfPresent(MCPConfigDelivery.self, forKey: .mcpConfig) ?? .none
        sandbox = try c.decodeIfPresent(SandboxSupport.self, forKey: .sandbox) ?? .none
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    enum CodingKeys: String, CodingKey {
        case kind, command, args, env, promptVia, parse, mcpConfig, sandbox, label
    }

    /// The arguments for `effort`: its own list, else `medium`'s, else none.
    public func arguments(for effort: String) -> [String] {
        args[effort] ?? args["medium"] ?? []
    }

    /// The effort levels this profile maps, in `low`, `medium`, `high` order; all three when
    /// `args` is empty (the arguments do not depend on effort).
    public var supportedEfforts: [String] {
        args.isEmpty ? Self.efforts : Self.efforts.filter { args[$0] != nil }
    }

    /// The first problem with this profile, or `nil`.
    var problem: String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return "empty command" }
        if let unknown = args.keys.sorted().first(where: { !Self.efforts.contains($0) }) {
            return "unknown effort \(unknown) in args"
        }
        let usesPlaceholder = args.values.joined().contains("{mcpConfig}")
        if kind == .exec, mcpConfig == .file, !usesPlaceholder {
            return "mcpConfig is file but no argument contains {mcpConfig}"
        }
        return nil
    }

    /// The command that starts an adapter for this profile.
    ///
    /// - Parameters:
    ///   - name: the profile's name, passed to `arya-exec-adapter` for exec profiles.
    ///   - profilesFile: the `adapters.json` path, passed to `arya-exec-adapter`.
    ///   - effort: the run's effort.
    ///   - environment: the complete base environment; `env` is added on top.
    ///   - execAdapter: the `arya-exec-adapter` executable (a path or a name on `PATH`).
    public func command(
        name: String, profilesFile: String, effort: String, environment: [String: String],
        execAdapter: String = "arya-exec-adapter"
    ) -> AdapterCommand {
        let merged = environment.merging(env) { _, profile in profile }
        switch kind {
        case .adapter:
            return AdapterCommand(
                executable: command, arguments: arguments(for: effort), environment: merged)
        case .exec:
            return AdapterCommand(
                executable: execAdapter,
                arguments: ["--profile", name, "--profiles", profilesFile],
                environment: merged)
        }
    }
}
