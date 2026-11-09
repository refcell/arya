import Foundation

/// macOS `sandbox-exec` support: a ready profile for runs and the launch wrapper.
public enum OSSandbox {
    /// Where macOS keeps `sandbox-exec`.
    public static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// Whether this machine can run a sandboxed harness.
    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExecPath)
    }

    /// Whether a sandboxed harness may open network connections.
    public enum NetworkAccess: Sendable, Hashable {
        /// Needed by harnesses that call a hosted model.
        case allowed
        /// No outbound IP connections; stdio tools still work.
        case denied
    }

    /// A profile that allows everything except writes outside `(param "WORKDIR")`, the
    /// standard `/dev` nodes, and `extraWritablePaths` (for example a harness's own state
    /// directory), and that optionally denies outbound network connections.
    public static func profileConfiningWrites(
        extraWritablePaths: [String] = [], network: NetworkAccess = .allowed
    ) -> String {
        let extras = extraWritablePaths.map { "  (subpath \(quoted($0)))" }
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write*",
            "  (subpath (param \"WORKDIR\"))",
            "  (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\")",
            "  (literal \"/dev/stdout\") (literal \"/dev/stderr\") (regex #\"^/dev/fd/\")",
        ]
        lines += extras
        lines.append(")")
        if network == .denied { lines.append("(deny network-outbound (remote ip))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A request for `profileConfiningWrites` bound to `workdir`.
    public static func confiningWrites(
        to workdir: String, extraWritablePaths: [String] = [], network: NetworkAccess = .allowed
    ) -> SandboxRequest {
        SandboxRequest(
            profile: profileConfiningWrites(
                extraWritablePaths: extraWritablePaths, network: network),
            params: ["WORKDIR": canonicalPath(workdir)])
    }

    /// `command` launched under `request` with `sandbox-exec -p <profile> -D NAME=value …`.
    public static func wrap(
        _ command: AdapterCommand, in request: SandboxRequest,
        sandboxExec: String = OSSandbox.sandboxExecPath
    ) -> AdapterCommand {
        var arguments = ["-p", request.profile]
        for name in request.params.keys.sorted() {
            arguments += ["-D", "\(name)=\(request.params[name] ?? "")"]
        }
        // A bare name is looked up on PATH by env, as the unsandboxed launch does.
        if !command.executable.contains("/") { arguments.append("/usr/bin/env") }
        arguments.append(command.executable)
        arguments += command.arguments
        var wrapped = command
        wrapped.executable = sandboxExec
        wrapped.arguments = arguments
        return wrapped
    }

    /// The sandbox matches resolved paths (`/private/var/…`, not `/var/…`). A path that does
    /// not exist yet is used as given.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func quoted(_ path: String) -> String {
        let escaped = canonicalPath(path).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
