import AryaCore
import Foundation

/// Reasons a `routine` action cannot be turned into an invocation.
public enum RoutineActionError: Error, Equatable, Sendable {
    case missingName
    case invalidParams(String)
    case notLive(String)
    case versionMismatch(name: String, live: String, requested: String)
    case notExecutable(name: String, language: RoutineLanguage)
    case content(RoutineContentError)
}

/// Everything needed to run one routine once. Built by `RoutineInvocation.prepare` from a
/// `routine` action's `params` and the steward's live library.
public struct RoutineInvocation: Sendable, Equatable {
    public static let defaultTimeoutSeconds = 60
    public static let defaultMaxOutputBytes = 64 * 1024

    public var name: String
    public var version: String
    public var content: String
    /// Positional arguments (`params.args`), passed as `$1`, `$2`, ….
    public var arguments: [String]
    /// Text on standard input (`params.input`); empty input when nil.
    public var input: String?
    /// The run's scratch directory; the routine runs there.
    public var workdir: URL
    public var timeoutSeconds: Int
    /// Cap per stream; output past it is dropped and flagged as truncated.
    public var maxOutputBytes: Int
    /// Extra environment variables. The routine never inherits arya's environment.
    public var environment: [String: String]

    public init(
        name: String, version: String, content: String, arguments: [String] = [],
        input: String? = nil, workdir: URL,
        timeoutSeconds: Int = defaultTimeoutSeconds,
        maxOutputBytes: Int = defaultMaxOutputBytes,
        environment: [String: String] = [:]
    ) {
        self.name = name
        self.version = version
        self.content = content
        self.arguments = arguments
        self.input = input
        self.workdir = workdir
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.maxOutputBytes = max(0, maxOutputBytes)
        self.environment = environment
    }

    /// The process environment: a fixed `PATH`, `HOME` and `TMPDIR` set to the workdir, the C
    /// locale, the routine's name and version, then `environment` on top.
    public var processEnvironment: [String: String] {
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": workdir.path,
            "TMPDIR": workdir.path,
            "LC_ALL": "C",
            "ARYA_ROUTINE": name,
            "ARYA_ROUTINE_VERSION": version,
        ]
        env.merge(environment) { _, extra in extra }
        return env
    }

    /// Resolves a `routine` action: `params.name` (required), `params.version` (optional pin
    /// that must equal the live version), `params.args` (array of strings), and `params.input`
    /// (string). Only the live `sh` version of a routine can run.
    public static func prepare(
        params: JSONValue, steward: StewardID, library: RoutineLibrary,
        store: some RoutineBlobStore, workdir: URL,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) throws(RoutineActionError) -> RoutineInvocation {
        guard let name = params["name"]?.stringValue, !name.isEmpty else { throw .missingName }
        guard let live = library.live(steward: steward, name: name) else {
            throw .notLive(name)
        }
        if let pinned = params["version"] {
            guard let requested = pinned.stringValue else {
                throw .invalidParams("version must be a string")
            }
            guard requested == live.version else {
                throw .versionMismatch(name: name, live: live.version, requested: requested)
            }
        }
        guard live.language == .sh else {
            throw .notExecutable(name: name, language: live.language)
        }
        let content: String
        do { content = try live.content(from: store) } catch { throw .content(error) }
        return RoutineInvocation(
            name: name, version: live.version, content: content,
            arguments: try strings(params["args"]), input: try input(params["input"]),
            workdir: workdir, timeoutSeconds: timeoutSeconds)
    }

    private static func strings(_ value: JSONValue?) throws(RoutineActionError) -> [String] {
        guard let value, value != .null else { return [] }
        guard let items = value.arrayValue else {
            throw .invalidParams("args must be an array of strings")
        }
        var out: [String] = []
        for item in items {
            guard let text = item.stringValue else {
                throw .invalidParams("args must be an array of strings")
            }
            out.append(text)
        }
        return out
    }

    private static func input(_ value: JSONValue?) throws(RoutineActionError) -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue else { throw .invalidParams("input must be a string") }
        return text
    }
}

/// What running a routine produced; recorded as the executor output of `action.executed` (exit
/// status 0) or `action.failed` (anything else).
public struct RoutineOutcome: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        /// The script exited; see `exitCode`.
        case exited
        /// The script was killed by a signal it did not send itself; see `signal`.
        case signaled
        /// The script ran past `timeoutSeconds` and was killed.
        case timedOut = "timed_out"
    }

    public var v: Int
    public var name: String
    public var version: String
    public var status: Status
    public var exitCode: Int32?
    public var signal: Int32?
    public var stdout: String
    public var stderr: String
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        name: String, version: String, status: Status, exitCode: Int32? = nil,
        signal: Int32? = nil, stdout: String = "", stderr: String = "",
        stdoutTruncated: Bool = false, stderrTruncated: Bool = false
    ) {
        self.v = 1
        self.name = name
        self.version = version
        self.status = status
        self.exitCode = exitCode
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    /// Whether the routine succeeded (exited with status 0).
    public var succeeded: Bool { status == .exited && exitCode == 0 }

    private enum CodingKeys: String, CodingKey {
        case v
        case name
        case version
        case status
        case exitCode
        case signal
        case stdout
        case stderr
        case stdoutTruncated
        case stderrTruncated
    }
}
