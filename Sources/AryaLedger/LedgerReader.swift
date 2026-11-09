import Foundation

/// Reads the ledger in `home/ledger/` without taking the append lock. Readers see complete
/// lines only: a final line with no trailing newline is still being written (or torn) and is
/// skipped until it completes or the store repairs it.
public struct LedgerReader: Sendable {
    public let directory: URL

    public init(home: URL) {
        directory = home.appendingPathComponent("ledger", isDirectory: true)
    }

    /// Every event with `seq >= from`, in order. Each line's hash is checked; a bad line
    /// throws `LedgerReadError`. Use `LedgerVerifier` for chain and continuity checks.
    public func events(from seq: Int64 = 1) throws -> [Event] {
        var out: [Event] = []
        try forEach(from: seq) { out.append($0) }
        return out
    }

    /// Calls `body` with each event with `seq >= from`, in order, streaming segment by
    /// segment. Segments wholly before `from` are skipped by peeking at their first line.
    public func forEach(from seq: Int64 = 1, _ body: (Event) throws -> Void) throws {
        let segments = try existingSegments()
        let start = try firstSegmentIndex(containing: seq, in: segments)
        for (index, segment) in segments[start...].enumerated() {
            let skip = index == 0 ? try linesBefore(seq, in: segment) : 0
            do {
                var first = skip > 0
                try scan(segment, skipLines: skip) { event, _, _ in
                    // Skipping assumes contiguous seqs; on a damaged ledger, rescan in full.
                    if first, event.seq != seq { throw RescanSegment() }
                    first = false
                    if event.seq >= seq { try body(event) }
                }
            } catch is RescanSegment {
                try scan(segment) { event, _, _ in
                    if event.seq >= seq { try body(event) }
                }
            }
        }
    }

    /// Follows the ledger: returns events after `after` as they are appended, polling every
    /// `interval`. Ends when the task is cancelled. Polling keeps it simple and portable;
    /// the ledger is small and appends are infrequent.
    public func follow(
        after seq: Int64, interval: Duration = .milliseconds(200)
    ) -> AsyncThrowingStream<Event, any Error> {
        let reader = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var last = seq
                do {
                    while !Task.isCancelled {
                        try reader.forEach(from: last + 1) { event in
                            continuation.yield(event)
                            last = event.seq
                        }
                        try await Task.sleep(for: interval)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    func existingSegments() throws -> [Segment] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try Segment.list(in: directory)
    }

    private func firstSegmentIndex(containing seq: Int64, in segments: [Segment]) throws -> Int {
        guard seq > 1, segments.count > 1 else { return 0 }
        var chosen = 0
        for (index, segment) in segments.enumerated() {
            guard let first = try firstEvent(of: segment) else { continue }
            if first.seq <= seq { chosen = index } else { break }
        }
        return chosen
    }

    /// Lines of `segment` that hold events before `seq`, assuming contiguous `seq`s from the
    /// segment's first event.
    private func linesBefore(_ seq: Int64, in segment: Segment) throws -> Int {
        guard seq > 1, let first = try firstEvent(of: segment), seq > first.seq else { return 0 }
        return Int(seq - first.seq)
    }

    private func firstEvent(of segment: Segment) throws -> Event? {
        var found: Event?
        try scan(segment, stopAfterFirst: true) { event, _, _ in found = event }
        return found
    }

    /// Calls `body(event, offset, lineNumber)` for each complete line of `segment`.
    func scan(
        _ segment: Segment, stopAfterFirst: Bool = false, skipLines: Int = 0,
        _ body: (Event, Int64, Int) throws -> Void
    ) throws {
        try scanLines(segment, stopAfterFirst: stopAfterFirst, skipLines: skipLines) {
            line, offset, number in
            let event: Event
            do {
                event = try LedgerLine.open(line)
            } catch let problem as LineProblem {
                throw LedgerReadError(
                    segment: segment.name, line: number, offset: offset, problem: problem)
            }
            try body(event, offset, number)
        }
    }

    /// Calls `body(bytes, offset, lineNumber)` for each newline-terminated line, reading the
    /// file in 1 MiB chunks. Line numbers start at 1. Lines before `skipLines` are counted but
    /// not passed to `body`.
    func scanLines(
        _ segment: Segment, stopAfterFirst: Bool = false, skipLines: Int = 0,
        _ body: (ArraySlice<UInt8>, Int64, Int) throws -> Void
    ) throws {
        let fd = try FileIO.open(segment.url, O_RDONLY)
        defer { close(fd) }
        let size = try FileIO.size(fd, name: segment.name)
        var buffer: [UInt8] = []
        var bufferStart: Int64 = 0
        var readOffset: Int64 = 0
        var number = 0
        while readOffset < size {
            let chunk = try FileIO.read(
                fd, at: readOffset, count: Int(min(1 << 20, size - readOffset)),
                name: segment.name)
            if chunk.isEmpty { break }
            readOffset += Int64(chunk.count)
            buffer += chunk
            var lineStart = 0
            for newline in Self.newlines(in: buffer) {
                number += 1
                if number > skipLines {
                    try body(buffer[lineStart..<newline], bufferStart + Int64(lineStart), number)
                    if stopAfterFirst { return }
                }
                lineStart = newline + 1
            }
            buffer.removeFirst(lineStart)
            bufferStart += Int64(lineStart)
        }
    }

    /// Offsets of every `\n` in `bytes`, found with `memchr`.
    static func newlines(in bytes: [UInt8]) -> [Int] {
        var out: [Int] = []
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                guard let hit = memchr(base + offset, 0x0A, raw.count - offset) else { break }
                let index = base.distance(to: UnsafeRawPointer(hit))
                out.append(index)
                offset = index + 1
            }
        }
        return out
    }
}

private struct RescanSegment: Error {}

/// A line that failed its hash or envelope check while reading.
public struct LedgerReadError: Error, Hashable, Sendable, CustomStringConvertible {
    public var segment: String
    /// 1-based line number within the segment.
    public var line: Int
    public var offset: Int64
    public var problem: LineProblem

    public var description: String { "\(segment):\(line): \(problem)" }
}
