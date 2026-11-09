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

/// Forwards an agent's stderr and remembers the first line that shows the OS sandbox refusing
/// an operation, so the run can report it in one sentence.
final class SandboxDenialWatcher: StderrSink {
    private let forward: any StderrSink
    private let state = Locked((pending: Data(), firstDenial: String?.none))

    /// What denied operations print: the `EPERM` text shells, tools, and runtimes use.
    static let markers = ["Operation not permitted", "operation not permitted"]

    init(forwardingTo forward: any StderrSink) { self.forward = forward }

    func append(_ data: Data) {
        forward.append(data)
        state.withLock { state in
            guard state.firstDenial == nil else { return }
            state.pending.append(data)
            while let newline = state.pending.firstIndex(of: 0x0A) {
                let line = String(decoding: state.pending[..<newline], as: UTF8.self)
                state.pending = Data(state.pending[state.pending.index(after: newline)...])
                if Self.markers.contains(where: line.contains) {
                    state.firstDenial = line.trimmingCharacters(in: .whitespaces)
                    state.pending = Data()
                    return
                }
            }
            // Keep a bounded tail while waiting for a newline.
            if state.pending.count > 4096 { state.pending = Data(state.pending.suffix(4096)) }
        }
    }

    /// The first denied operation's stderr line, cut to 160 characters.
    var firstDenial: String? {
        state.withLock { state in
            if state.firstDenial == nil, !state.pending.isEmpty {
                let tail = String(decoding: state.pending, as: UTF8.self)
                if Self.markers.contains(where: tail.contains) {
                    state.firstDenial = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return state.firstDenial.map { String($0.prefix(160)) }
        }
    }

    /// The sentence the run reports, or `nil` when nothing was denied.
    var report: String? {
        firstDenial.map {
            "The sandbox blocked the agent from writing outside its workdir or using the "
                + "network (\($0))."
        }
    }
}
