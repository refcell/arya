import Darwin
import Foundation

/// Reasons a routine could not be started. A routine that starts and fails is a
/// `RoutineOutcome`, not an error.
public enum RoutineExecutionError: Error, Equatable, Sendable {
    case workdirMissing(String)
    case pipeFailed(Int32)
    case spawnFailed(Int32)
}

/// Runs routine invocations. The runtime's executor for the `routine` action kind calls this;
/// tests substitute a fake.
public protocol RoutineRunning: Sendable {
    func run(_ invocation: RoutineInvocation) throws(RoutineExecutionError) -> RoutineOutcome
}

/// Runs `sh` routines as `/bin/sh -c <content> <name> <args…>` in the invocation's workdir,
/// in a new process group with a clean environment. On timeout, and after the script exits,
/// the whole group is killed so no background process outlives the action. Standard output
/// and error are captured up to `maxOutputBytes` each.
public struct ShellRoutineRunner: RoutineRunning {
    public var shell: String

    public init(shell: String = "/bin/sh") {
        self.shell = shell
    }

    public func run(_ invocation: RoutineInvocation) throws(RoutineExecutionError)
        -> RoutineOutcome
    {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: invocation.workdir.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw .workdirMissing(invocation.workdir.lastPathComponent) }
        let pipes = try Pipes()
        let pid = try spawn(invocation, pipes: pipes)
        pipes.closeChildEnds()
        let stdout = PipeReader(fd: pipes.stdout[0], limit: invocation.maxOutputBytes)
        let stderr = PipeReader(fd: pipes.stderr[0], limit: invocation.maxOutputBytes)
        let feeder = InputFeeder(fd: pipes.stdin[1], data: Data((invocation.input ?? "").utf8))
        let exit = ExitWaiter(pid: pid)
        let finished = exit.wait(seconds: invocation.timeoutSeconds)
        kill(-pid, SIGKILL)
        let status = exit.wait()
        feeder.join()
        let out = stdout.finish()
        let err = stderr.finish()
        let termination = finished ? Self.decode(status) : (.timedOut, nil, nil)
        return RoutineOutcome(
            name: invocation.name, version: invocation.version, status: termination.0,
            exitCode: termination.1, signal: termination.2,
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self),
            stdoutTruncated: out.truncated, stderrTruncated: err.truncated)
    }

    private func spawn(_ invocation: RoutineInvocation, pipes: Pipes)
        throws(RoutineExecutionError) -> pid_t
    {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipes.stdin[0], 0)
        posix_spawn_file_actions_adddup2(&actions, pipes.stdout[1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipes.stderr[1], 2)
        for fd in pipes.all { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, invocation.workdir.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)
        let flags =
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        let argv = [shell, "-c", invocation.content, invocation.name] + invocation.arguments
        let envp = invocation.processEnvironment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                posix_spawn(&pid, shell, &actions, &attributes, argvPointers, envPointers)
            }
        }
        guard rc == 0 else {
            pipes.closeAll()
            throw .spawnFailed(rc)
        }
        return pid
    }

    /// Splits a `waitpid` status into exited/signaled with code or signal.
    static func decode(_ status: Int32) -> (RoutineOutcome.Status, Int32?, Int32?) {
        let signal = status & 0x7f
        if signal == 0 { return (.exited, (status >> 8) & 0xff, nil) }
        return (.signaled, nil, signal)
    }
}

/// The three pipes of a child: `[read, write]` each.
private final class Pipes: @unchecked Sendable {
    var stdin: [Int32] = [-1, -1]
    var stdout: [Int32] = [-1, -1]
    var stderr: [Int32] = [-1, -1]

    init() throws(RoutineExecutionError) {
        for index in 0..<3 {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                let code = errno
                closeAll()
                throw .pipeFailed(code)
            }
            switch index {
            case 0: stdin = fds
            case 1: stdout = fds
            default: stderr = fds
            }
        }
        _ = fcntl(stdin[1], F_SETNOSIGPIPE, 1)
    }

    var all: [Int32] { (stdin + stdout + stderr).filter { $0 >= 0 } }

    func closeChildEnds() {
        close(stdin[0])
        close(stdout[1])
        close(stderr[1])
    }

    func closeAll() {
        for fd in all { close(fd) }
    }
}

/// Reads a pipe to EOF on its own thread, keeping at most `limit` bytes.
private final class PipeReader: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var truncated = false

    init(fd: Int32, limit: Int) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let room = max(0, limit - data.count)
                if count > room { truncated = true }
                data.append(contentsOf: buffer.prefix(min(count, room)))
            }
            close(fd)
            done.signal()
        }
    }

    func finish() -> (data: Data, truncated: Bool) {
        done.wait()
        return (data, truncated)
    }
}

/// Writes standard input on its own thread, then closes it. A routine that does not read its
/// input makes the write fail with EPIPE, which is ignored.
private final class InputFeeder: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)

    init(fd: Int32, data: Data) {
        Thread.detachNewThread { [done] in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count, let base = raw.baseAddress {
                    let written = write(fd, base + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { break }
                    offset += written
                }
            }
            close(fd)
            done.signal()
        }
    }

    func join() { done.wait() }
}

/// Waits for a child on its own thread so the caller can wait with a timeout.
private final class ExitWaiter: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var status: Int32 = 0
    private var collected = false

    init(pid: pid_t) {
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
            status = raw
            done.signal()
        }
    }

    /// Whether the child exited within `seconds`.
    func wait(seconds: Int) -> Bool {
        let exited = done.wait(timeout: .now() + .seconds(seconds)) == .success
        if exited { collected = true }
        return exited
    }

    /// The raw `waitpid` status, waiting as long as needed.
    func wait() -> Int32 {
        if !collected {
            done.wait()
            collected = true
        }
        return status
    }
}

/// Calls `body` with a NULL-terminated C string array.
private func withCStrings<R>(
    _ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R
) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return body(pointers)
}
