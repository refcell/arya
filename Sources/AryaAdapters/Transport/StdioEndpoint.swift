import Foundation

/// The adapter side of a connection over this process's stdin and stdout, for adapter
/// executables such as `arya-fake-adapter`.
public final class StdioEndpoint: AdapterEndpoint {
    public let incoming: AsyncStream<Data>
    private let output = FileHandle.standardOutput
    private let lock = Locked(())

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .unbounded)
        incoming = stream
        let splitter = Locked(LineSplitter())
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let rest = splitter.withLock({ $0.finish() }) { continuation.yield(rest) }
                continuation.finish()
                return
            }
            for line in splitter.withLock({ $0.append(data) }) { continuation.yield(line) }
        }
    }

    public func write(_ line: Data) async {
        lock.withLock { _ in try? output.write(contentsOf: line) }
    }

    /// Exits the process with the status `exit` describes.
    public func close(_ exit: AdapterExit) async {
        // Hold the write lock so no half-written line precedes the exit.
        lock.withLock { _ in
            switch exit {
            case .exited(let status): Foundation.exit(status)
            case .signaled(let signal):
                Foundation.signal(signal, SIG_DFL)
                raise(signal)
                Foundation.exit(128 + signal)
            case .closed: Foundation.exit(0)
            }
        }
    }
}
