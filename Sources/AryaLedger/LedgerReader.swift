import AryaCore
import Foundation

/// Reads the ledger in `home/ledger/` without taking the append lock. Readers see complete
/// lines only: a final line with no trailing newline is still being written (or torn) and is
/// skipped until it completes or the store repairs it.
///
/// In an encrypted home, sealed payloads are opened with the key registered for the home
/// (`HomeEncryption`); a missing key throws `HomeEncryptionError.locked`. `LedgerVerifier`
/// checks lines without opening them.
///
/// On a compacted ledger (retention, `LedgerStore.compact`) the segments moved to `archive/`
/// are read first, so history folds from `seq` 1 still see every event; nothing a fold needs
/// disappears when retention runs. Pass `archive: false` for the live ledger alone: the
/// verifier, checkpoints, the projection cache (which seeds from checkpoints instead), and
/// the retention plan read only `ledger/`.
public struct LedgerReader: Sendable {
    public let directory: URL
    /// Whether archived segments are read before the live ones.
    public let archive: Bool

    public init(home: URL, archive: Bool = true) {
        directory = home.appendingPathComponent("ledger", isDirectory: true)
        self.archive = archive
    }

    /// The home directory.
    public var home: URL { directory.deletingLastPathComponent() }

    /// Calls `body` with every event in order, sealed payloads left sealed: an envelope read
    /// (types, stewards, actors, times) that needs no key.
    public func forEachEnvelope(_ body: (Event) throws -> Void) throws {
        for segment in try existingSegments() {
            try scan(segment, openSealed: false) { event, _, _ in try body(event) }
        }
    }

    /// `event` with a sealed payload opened.
    func opened(_ event: Event) throws -> Event {
        guard SealedPayload.isSealed(event) else { return event }
        return try HomeEncryption.opened(event, home: home)
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
        try forEach(LedgerFilter(), from: seq, body)
    }

    /// Every event matching `filter` with `seq >= from`, in order.
    public func events(_ filter: LedgerFilter, from seq: Int64 = 1) throws -> [Event] {
        var out: [Event] = []
        try forEach(filter, from: seq) { out.append($0) }
        return out
    }

    /// Every event at or after `since`, in order: the long-range read behind the outcome,
    /// recap, and activity views.
    public func events(since: Timestamp) throws -> [Event] {
        try events(LedgerFilter(since: since))
    }

    /// Calls `body` with each event matching `filter` with `seq >= from`, in order. Lines that
    /// cannot match are skipped before they are hashed or parsed (`LineSieve`), and a `since`
    /// bound skips whole segments that end before it, judged by the next segment's first
    /// `at`. That assumes `at` does not go backwards across a segment boundary; within the
    /// segments read, every line is compared.
    public func forEach(
        _ filter: LedgerFilter, from seq: Int64 = 1, _ body: (Event) throws -> Void
    ) throws {
        let sieve = LineSieve(filter)
        let segments = try existingSegments()
        let start = max(
            try firstSegmentIndex(containing: seq, in: segments),
            try firstSegmentIndex(since: filter.since, in: segments))
        for (index, segment) in segments[start...].enumerated() {
            let skip = index == 0 ? try linesBefore(seq, in: segment) : 0
            func deliver(_ event: Event) throws {
                if event.seq >= seq, filter.matches(event) { try body(event) }
            }
            do {
                // Skipping assumes contiguous seqs, so the first line after a skip is always
                // opened and checked; on a damaged ledger, rescan in full.
                try scan(segment, skipLines: skip, sieve: sieve, expectFirst: skip > 0 ? seq : nil)
                {
                    event, _, _ in try deliver(event)
                }
            } catch is RescanSegment {
                LineMarks.shared.forget(segment.url.path)
                try scan(segment, sieve: sieve) { event, _, _ in try deliver(event) }
            }
        }
    }

    /// Follows the ledger: returns events after `after` that match `filter` as they are
    /// appended, polling every `interval`. Ends when the task is cancelled. Lines that cannot
    /// match are sieved out before they are opened, and each poll starts after the head seen
    /// by the previous one, so a quiet filter does not rescan. Polling keeps it simple and
    /// portable; appends are infrequent.
    public func follow(
        _ filter: LedgerFilter = LedgerFilter(), after seq: Int64,
        interval: Duration = .milliseconds(200)
    ) -> AsyncThrowingStream<Event, any Error> {
        let reader = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var last = seq
                do {
                    while !Task.isCancelled {
                        // Every event up to this head is scanned by the pass below.
                        let head = try reader.headSeq() ?? last
                        try reader.forEach(filter, from: last + 1) { event in
                            continuation.yield(event)
                            last = max(last, event.seq)
                        }
                        last = max(last, head)
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

    /// The events with these `seq`s that are live, by `seq`, in one pass per segment that
    /// opens only the named lines. For widgets that open the events an index points at
    /// (`LedgerIndex.StewardSpan.lastSeqByType`).
    public func events(at seqs: some Sequence<Int64>) throws -> [Int64: Event] {
        let wanted = Set(seqs.filter { $0 >= 1 })
        guard let lowest = wanted.min() else { return [:] }
        var out: [Int64: Event] = [:]
        let segments = try existingSegments()
        let start = try firstSegmentIndex(containing: lowest, in: segments)
        for segment in segments[start...] {
            guard let first = try firstEvent(of: segment) else { continue }
            var contiguous = true
            try scanLines(segment) { line, offset, number in
                let seq = first.seq + Int64(number) - 1
                guard !contiguous || wanted.contains(seq) else { return }
                let event: Event
                do {
                    event = try opened(LedgerLine.open(line))
                } catch let problem as LineProblem {
                    throw LedgerReadError(
                        segment: segment.name, line: number, offset: offset, problem: problem)
                }
                // A damaged segment breaks the line-to-seq rule; open the rest in full.
                if event.seq != seq { contiguous = false }
                if wanted.contains(event.seq) { out[event.seq] = event }
            }
            if out.count == wanted.count { break }
        }
        return out
    }

    /// The newest complete event's `seq`, or nil for an empty ledger.
    func headSeq() throws -> Int64? {
        guard let newest = try existingSegments().last else { return nil }
        return try lastEvent(of: newest)?.seq
    }

    // MARK: - Internals

    /// The segments this reader reads, oldest first: archived ones older than the first live
    /// segment (when `archive`), then the live ones.
    func existingSegments() throws -> [Segment] {
        let live = try liveSegments()
        guard archive else { return live }
        let archived = home.appendingPathComponent("archive", isDirectory: true)
        guard FileManager.default.fileExists(atPath: archived.path) else { return live }
        let older = try Segment.list(in: archived).filter {
            $0.number < (live.first?.number ?? Int.max)
        }
        return older + live
    }

    /// The segments in `ledger/`, oldest first.
    func liveSegments() throws -> [Segment] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try Segment.list(in: directory)
    }

    func firstSegmentIndex(containing seq: Int64, in segments: [Segment]) throws -> Int {
        guard seq > 1, segments.count > 1 else { return 0 }
        var chosen = 0
        for (index, segment) in segments.enumerated() {
            guard let first = try firstEvent(of: segment) else { continue }
            if first.seq <= seq { chosen = index } else { break }
        }
        return chosen
    }

    /// The last segment whose first event is before `since`; earlier segments end before it.
    private func firstSegmentIndex(since: Timestamp?, in segments: [Segment]) throws -> Int {
        guard let since, segments.count > 1 else { return 0 }
        var chosen = 0
        for (index, segment) in segments.enumerated() {
            guard let first = try firstEvent(of: segment) else { continue }
            if first.at < since { chosen = index } else { break }
        }
        return chosen
    }

    /// Lines of `segment` that hold events before `seq`, assuming contiguous `seq`s from the
    /// segment's first event.
    private func linesBefore(_ seq: Int64, in segment: Segment) throws -> Int {
        guard seq > 1, let first = try firstEvent(of: segment), seq > first.seq else { return 0 }
        return Int(seq - first.seq)
    }

    func firstEvent(of segment: Segment) throws -> Event? {
        var found: Event?
        try scan(segment, stopAfterFirst: true, openSealed: false) { event, _, _ in
            found = event
        }
        return found
    }

    /// Calls `body(event, offset, lineNumber)` for each complete line of `segment` that
    /// `sieve` admits. When `expectFirst` is set, the first line read is always opened and
    /// must hold that `seq`, or the scan throws `RescanSegment`. With `openSealed` false,
    /// sealed payloads stay sealed (envelope reads need no key).
    func scan(
        _ segment: Segment, stopAfterFirst: Bool = false, skipLines: Int = 0,
        sieve: LineSieve? = nil, expectFirst: Int64? = nil, openSealed: Bool = true,
        _ body: (Event, Int64, Int) throws -> Void
    ) throws {
        let sieve = sieve?.passesAll == false ? sieve : nil
        var expected = expectFirst
        try scanLines(segment, stopAfterFirst: stopAfterFirst, skipLines: skipLines) {
            line, offset, number in
            if expected == nil, let sieve,
                !line.withUnsafeBufferPointer({ sieve.admits($0) })
            {
                return
            }
            let event: Event
            do {
                let raw = try LedgerLine.open(line)
                event = openSealed ? try opened(raw) : raw
            } catch let problem as LineProblem {
                throw LedgerReadError(
                    segment: segment.name, line: number, offset: offset, problem: problem)
            }
            if let seq = expected {
                if event.seq != seq { throw RescanSegment() }
                expected = nil
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
        var readOffset: Int64 = 0
        var number = 0
        // A tail read resumes where the last full scan of this segment ended instead of
        // counting every line again. The mark is trusted only when it is not past the lines to
        // skip, fits the file, and follows a newline; the caller's first-line seq check
        // (`expectFirst`) still catches a segment that changed underneath it.
        if skipLines > 0, let mark = LineMarks.shared.nearest(segment.url.path, atMost: skipLines),
            mark.offset <= size,
            try mark.offset == 0
                || FileIO.read(fd, at: mark.offset - 1, count: 1, name: segment.name) == [0x0A]
        {
            readOffset = mark.offset
            number = mark.line
        }
        var bufferStart = readOffset
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
            LineMarks.shared.note(segment.url.path, line: number, offset: bufferStart)
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

/// Line starts seen while scanning each segment, one per 1 MiB chunk read: how many complete
/// lines come before a byte offset. Process-wide, so every reader of a home shares them.
private final class LineMarks: @unchecked Sendable {
    static let shared = LineMarks()
    private static let limit = 4096
    private let lock = NSLock()
    /// Per segment path, sorted by line.
    private var marks: [String: [(line: Int, offset: Int64)]] = [:]

    /// The mark with the most lines before it, at most `line`.
    func nearest(_ path: String, atMost line: Int) -> (line: Int, offset: Int64)? {
        lock.withLock { marks[path]?.last { $0.line <= line } }
    }

    func forget(_ path: String) {
        lock.withLock { marks[path] = nil }
    }

    func note(_ path: String, line: Int, offset: Int64) {
        lock.withLock {
            var list = marks[path] ?? []
            if let at = list.firstIndex(where: { $0.line >= line }) {
                if list[at].line == line {
                    list[at] = (line, offset)
                } else {
                    list.insert((line, offset), at: at)
                }
            } else {
                list.append((line, offset))
            }
            if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
            marks[path] = list
        }
    }
}

/// A line that failed its hash or envelope check while reading.
public struct LedgerReadError: Error, Hashable, Sendable, CustomStringConvertible {
    public var segment: String
    /// 1-based line number within the segment.
    public var line: Int
    public var offset: Int64
    public var problem: LineProblem

    public var description: String { "\(segment):\(line): \(problem)" }
}
