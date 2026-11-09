import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import Foundation

/// A macOS `sandbox-exec` profile for a process arya starts on a run's behalf (decision 0040):
/// writes only under the run's workdir (plus the null, terminal, and descriptor devices), and no
/// network unless allowed. Reads stay open so tools and libraries load.
public struct Sandbox: Sendable, Hashable {
    /// The launcher.
    public static let executable = "/usr/bin/sandbox-exec"

    /// True when `sandbox-exec` works here: it exists and can apply a profile (it cannot
    /// when arya itself already runs in a sandbox). Probed once per process.
    public static let available: Bool = {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: executable)
        probe.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }()

    /// The run's workdir, symlinks resolved (the kernel checks real paths).
    public var workdir: String
    /// Whether the process may use the network.
    public var network: Bool

    /// A sandbox for `workdir`, which is created when missing.
    public init(workdir: String, network: Bool = false) throws {
        try FileManager.default.createDirectory(
            atPath: workdir, withIntermediateDirectories: true)
        self.workdir = Self.realPath(workdir)
        self.network = network
    }

    /// The SBPL profile.
    public var profile: String {
        var rules = ["(version 1)", "(allow default)"]
        if !network { rules.append("(deny network*)") }
        rules += [
            "(deny file-write*)",
            "(allow file-write* (subpath \(Self.quote(workdir))))",
            "(allow file-write* (literal \"/dev/null\") (literal \"/dev/zero\")"
                + " (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")"
                + " (regex #\"^/dev/fd/\"))",
        ]
        return rules.joined(separator: "\n")
    }

    /// `command args` under this sandbox; a command without a slash is looked up on `PATH`.
    public func wrap(_ command: String, _ args: [String]) -> (command: String, args: [String]) {
        let target = command.contains("/") ? [command] : ["/usr/bin/env", command]
        return (Self.executable, ["-p", profile] + target + args)
    }

    /// What `run.started.sandbox` records: the workdir and the MCP bindings allowed the
    /// network.
    public static func record(workdir: String, charter: Charter) -> JSONValue {
        let network = charter.bindings.filter { $0.kind == .mcp && $0.network }.map(\.id)
        return [
            "kind": "sandbox-exec", "workdir": .string(workdir),
            "network": .array(network.map { .string($0) }),
        ]
    }

    private static func quote(_ path: String) -> String {
        "\""
            + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Runs routines through `base` inside a sandbox on the invocation's workdir, with no network
/// (decision 0040). The script is passed through the environment, so no quoting is involved,
/// and those variables are removed before the routine starts.
public struct SandboxedRoutineRunner: RoutineRunning {
    private let base: any RoutineRunning

    /// Wraps `base`.
    public init(_ base: any RoutineRunning = ShellRoutineRunner()) { self.base = base }

    static let launcher = """
        exec /usr/bin/env -u ARYA_SANDBOX_PROFILE -u ARYA_SANDBOX_SCRIPT \
        /usr/bin/sandbox-exec -p "$ARYA_SANDBOX_PROFILE" /bin/sh -c "$ARYA_SANDBOX_SCRIPT" "$0" "$@"
        """

    public func run(_ invocation: RoutineInvocation) throws(RoutineExecutionError)
        -> RoutineOutcome
    {
        guard Sandbox.available,
            let sandbox = try? Sandbox(workdir: invocation.workdir.path, network: false)
        else { return try base.run(invocation) }
        var wrapped = invocation
        wrapped.content = Self.launcher
        wrapped.environment["ARYA_SANDBOX_PROFILE"] = sandbox.profile
        wrapped.environment["ARYA_SANDBOX_SCRIPT"] = invocation.content
        return try base.run(wrapped)
    }
}

/// `run.sandboxed`: how a sandboxed run's harness was confined, known only after the adapter
/// reported its capabilities (decision 0040). `os`: under arya's `sandbox-exec` profile (writes
/// only in the workdir and the adapter's own state; network allowed, since harnesses call hosted
/// models); `workdir`: only the harness's own write confinement; `none`: not confined.
public struct RunSandboxed: EventPayload {
    public static let type = EventType("run.sandboxed")
    public var harness: SandboxSupport

    /// Creates a payload.
    public init(harness: SandboxSupport) { self.harness = harness }

    enum CodingKeys: String, CodingKey { case harness }
}
