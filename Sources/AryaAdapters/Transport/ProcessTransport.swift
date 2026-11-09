import Foundation

/// Receives an adapter's stderr as it arrives. The runtime stores it as the run's transcript
/// blob.
public protocol StderrSink: Sendable {
    func append(_ data: Data)
}

/// A ``StderrSink`` that keeps stderr in memory.
public final class StderrBuffer: StderrSink {
    private let storage = Locked(Data())

    public init() {}

    public func append(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    /// Everything written so far.
    public var contents: Data { storage.withLock { $0 } }
}

/// The command line that starts an adapter process.
public struct AdapterCommand: Sendable, Hashable {
    /// A path, or a name looked up on `PATH` in `environment`.
    public var executable: String
    public var arguments: [String]
    /// The complete environment of the process. Callers pass it explicitly; library code
    /// never reads the host's environment.
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        executable: String, arguments: [String] = [], environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// An ``AdapterTransport`` over the stdin and stdout of a child process.
///
/// stdout is split into lines; stderr goes to a ``StderrSink``. `.ended` is delivered only
/// after the process has exited and stdout and stderr have been read to the end (or one second
/// has passed since the exit), so no output is lost.
public final class ProcessTransport: AdapterTransport {
    public let input: AsyncStream<TransportInput>
    private let continuation: AsyncStream<TransportInput>.Continuation
    private let process: Process
    private let stdin: FileHandle
    /// Writes to stdin run here, so a peer that stops reading cannot block the caller (or the
    /// actor calling it, and with it the request timeouts); terminating the peer ends the write.
    private let stdinQueue = DispatchQueue(label: "arya.adapter.stdin")
    private let state = Locked(ProcessState())

    private struct ProcessState {
        var splitter = LineSplitter()
        var stdoutDone = false
        var stderrDone = false
        var exit: AdapterExit?
        var ended = false
        var inputClosed = false
    }

    /// Starts `command` and connects to it.
    public static func launch(
        _ command: AdapterCommand, stderr: any StderrSink = StderrBuffer()
    ) throws(AdapterError) -> ProcessTransport {
        ignoreSIGPIPE
        let transport = ProcessTransport(command)
        try transport.run(stderr: stderr)
        return transport
    }

    /// Writing to the stdin of an exited child raises SIGPIPE, which would kill arya. Ignore
    /// it once per process so the write fails with EPIPE instead.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private init(_ command: AdapterCommand) {
        (input, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        process = Process()
        if command.executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
        }
        process.environment = command.environment
        if let directory = command.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        stdin = stdinPipe.fileHandleForWriting
    }

    private func run(stderr: any StderrSink) throws(AdapterError) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.readStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.stderrEnded()
            } else {
                stderr.append(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            let exit: AdapterExit =
                process.terminationReason == .uncaughtSignal
                ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
            self?.exited(exit)
        }
        do {
            try process.run()
        } catch {
            throw .launchFailed("\(error)")
        }
    }

    private func readStdout(_ data: Data) {
        let lines = state.withLock { state -> [Data] in
            if data.isEmpty {
                state.stdoutDone = true
                return state.splitter.finish().map { [$0] } ?? []
            }
            return state.splitter.append(data)
        }
        for line in lines { continuation.yield(.line(line)) }
        if data.isEmpty { endIfDone() }
    }

    private func stderrEnded() {
        state.withLock { $0.stderrDone = true }
        endIfDone()
    }

    private func exited(_ exit: AdapterExit) {
        state.withLock { $0.exit = exit }
        endIfDone()
        // A grandchild that inherited stdout can keep it open after the adapter exits; stop
        // waiting for end-of-file after a short delay so the exit is still reported.
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            self?.state.withLock { $0.stderrDone = true }
            self?.readStdout(Data())
        }
    }

    private func endIfDone() {
        let exit = state.withLock { state -> AdapterExit? in
            guard state.stdoutDone, state.stderrDone, let exit = state.exit, !state.ended else {
                return nil
            }
            state.ended = true
            return exit
        }
        guard let exit else { return }
        continuation.yield(.ended(exit))
        continuation.finish()
    }

    /// Queues `line` for stdin and returns; lines are written in order. A failed write means
    /// the peer is gone, which `.ended` reports, so it is not thrown here.
    public func write(_ line: Data) async throws {
        if state.withLock({ $0.inputClosed }) { throw AdapterError.writeFailed("stdin closed") }
        let stdin = self.stdin
        stdinQueue.async { try? stdin.write(contentsOf: line) }
    }

    public func closeInput() async {
        let first = state.withLock { state in
            defer { state.inputClosed = true }
            return !state.inputClosed
        }
        // After any queued writes.
        let stdin = self.stdin
        if first { stdinQueue.async { try? stdin.close() } }
    }

    public func terminate(grace: Duration) async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(for: grace)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// The child's process id.
    public var processIdentifier: Int32 { process.processIdentifier }
}
