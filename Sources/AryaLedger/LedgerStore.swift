import AryaCore
import Foundation

/// The append-only ledger in `home/ledger/`, safe to write from several processes at once
/// (decision 0013).
///
/// Each append takes `ledger.lock` with `flock`, re-reads the tail of the newest segment to
/// learn `seq` and `prev` (another process may have appended), writes one line per event,
/// `fsync`s, and releases the lock. A segment rolls over to the next number once a write
/// would take it past `segmentLimitBytes`.
///
/// A torn final line (no trailing newline, or not JSON) is repaired on open and before each
/// append: its bytes go to a blob, the segment is truncated, and a `system.repair` event
/// records it. A final line that is JSON but fails its hash or envelope check is a chain
/// break: the store refuses to append (`LedgerStoreError.chainBroken`) until a person
/// decides.
///
/// For each event the store reads `ambient.now()` and then `ambient.newID(EventID.self)`.
public final class LedgerStore: Sendable {
    public static let defaultSegmentLimitBytes: Int64 = 64 * 1024 * 1024

    public let home: URL
    public let ambient: Ambient
    public let segmentLimitBytes: Int64
    public let blobs: BlobStore
    /// `home/ledger`.
    public let directory: URL

    private let lockURL: URL
    private let threadLock = Locked(())

    /// Opens (creating if needed) the ledger in `home` and repairs a torn tail.
    public init(
        home: URL, ambient: Ambient, segmentLimitBytes: Int64 = LedgerStore.defaultSegmentLimitBytes
    ) throws {
        self.home = home
        self.ambient = ambient
        self.segmentLimitBytes = max(1, segmentLimitBytes)
        blobs = BlobStore(home: home)
        directory = home.appendingPathComponent("ledger", isDirectory: true)
        lockURL = home.appendingPathComponent("ledger.lock")
        try FileIO.makeDirectory(directory)
        try withAppendLock { _ = try $0.prepare() }
    }

    /// Appends one event and returns it as written.
    @discardableResult
    public func append(_ draft: EventDraft) throws -> Event {
        try append([draft])[0]
    }

    /// Appends events in order under one lock and one `fsync`. All or none are sealed; a
    /// crash mid-write leaves at most a torn final line, which the next open repairs.
    @discardableResult
    public func append(_ drafts: [EventDraft]) throws -> [Event] {
        if drafts.isEmpty { return [] }
        return try withAppendLock { writer in
            var head = try writer.prepare()
            var sealed: [(Event, [UInt8])] = []
            for draft in drafts {
                let at = ambient.now()
                let id = ambient.newID(EventID.self)
                let (event, line) = try LedgerLine.seal(
                    draft, seq: head.seq + 1, prev: head.hash, id: id, at: at)
                sealed.append((event, line))
                head = Head(seq: event.seq, hash: event.hash)
            }
            try writer.write(sealed.map(\.1))
            return sealed.map(\.0)
        }
    }

    /// The last written `seq` and `hash` (0 and the genesis hash for an empty ledger).
    public func head() throws -> (seq: Int64, hash: String) {
        let head = try withAppendLock { try $0.prepare() }
        return (head.seq, head.hash)
    }

    /// Segments, oldest first.
    public func segments() throws -> [Segment] {
        try Segment.list(in: directory)
    }

    /// Runs `body` holding the append lock, so no writer appends meanwhile.
    func exclusive<T>(_ body: () throws -> T) throws -> T {
        try withAppendLock { _ in try body() }
    }

    private func withAppendLock<T>(_ body: (inout Writer) throws -> T) throws -> T {
        try threadLock.withLock { _ in
            let fd = try FileIO.open(lockURL, O_RDWR | O_CREAT)
            defer { close(fd) }
            while flock(fd, LOCK_EX) != 0 {
                if errno != EINTR {
                    throw LedgerIOError(op: "flock", path: "ledger.lock", code: errno)
                }
            }
            defer { flock(fd, LOCK_UN) }
            var writer = Writer(store: self)
            return try body(&writer)
        }
    }

    struct Head {
        var seq: Int64
        var hash: String
    }

    /// Work done while holding the append lock.
    struct Writer {
        let store: LedgerStore

        /// Repairs a torn tail if needed and returns the current head.
        mutating func prepare() throws -> Head {
            let segments = try store.segments()
            guard let newest = segments.last else { return Head(seq: 0, hash: Event.genesisHash) }
            if let head = try repairIfTorn(newest) { return head }
            for segment in segments.reversed() {
                if let head = try lastHead(of: segment) { return head }
            }
            return Head(seq: 0, hash: Event.genesisHash)
        }

        /// Writes lines (without newlines) to the newest segment, rolling over as needed.
        func write(_ lines: [[UInt8]]) throws {
            var segment = try store.segments().last ?? newSegment(1)
            var fd = try FileIO.open(segment.url, O_WRONLY | O_APPEND | O_CREAT)
            var size = try FileIO.size(fd, name: segment.name)
            var pending: [UInt8] = []
            var createdSegment = size == 0
            defer { close(fd) }
            for line in lines {
                let length = Int64(line.count + 1)
                if size + Int64(pending.count) > 0,
                    size + Int64(pending.count) + length > store.segmentLimitBytes
                {
                    try FileIO.writeAll(fd, pending, name: segment.name)
                    try FileIO.sync(fd, name: segment.name)
                    close(fd)
                    pending.removeAll()
                    segment = newSegment(segment.number + 1)
                    fd = try FileIO.open(segment.url, O_WRONLY | O_APPEND | O_CREAT)
                    size = 0
                    createdSegment = true
                }
                pending += line
                pending.append(0x0A)
            }
            try FileIO.writeAll(fd, pending, name: segment.name)
            try FileIO.sync(fd, name: segment.name)
            if createdSegment { try FileIO.syncDirectory(store.directory) }
        }

        private func newSegment(_ number: Int) -> Segment {
            Segment(
                number: number, url: store.directory.appendingPathComponent(Segment.name(number)))
        }

        /// The head from a segment's last line, or nil if the segment is empty.
        private func lastHead(of segment: Segment) throws -> Head? {
            let fd = try FileIO.open(segment.url, O_RDONLY)
            defer { close(fd) }
            guard let tail = try SegmentTail.read(fd, name: segment.name) else { return nil }
            let event = try openTail(tail, segment: segment)
            return Head(seq: event.seq, hash: event.hash)
        }

        private func openTail(_ tail: SegmentTail, segment: Segment) throws -> Event {
            do {
                return try LedgerLine.open(tail.line)
            } catch let problem as LineProblem {
                throw LedgerStoreError.chainBroken(
                    segment: segment.name, offset: tail.offset, problem: problem)
            }
        }

        /// If the newest segment ends in a torn line, moves it to a blob, truncates, and
        /// appends `system.repair`. Returns the head after the repair, or nil if not torn.
        private mutating func repairIfTorn(_ segment: Segment) throws -> Head? {
            let fd = try FileIO.open(segment.url, O_RDWR)
            defer { close(fd) }
            guard let tail = try SegmentTail.read(fd, name: segment.name) else { return nil }
            let reason: String
            if !tail.terminated {
                reason = "no trailing newline"
            } else if (try? JSONSerialization.jsonObject(with: Data(tail.line))) == nil {
                reason = "not JSON"
            } else {
                return nil
            }
            let size = try FileIO.size(fd, name: segment.name)
            let torn = try FileIO.read(
                fd, at: tail.offset, count: Int(size - tail.offset),
                name: segment.name)
            let blob = try store.blobs.put(Data(torn))
            try FileIO.truncate(fd, to: tail.offset, name: segment.name)
            try FileIO.sync(fd, name: segment.name)
            let repair = try EventDraft(
                SystemRepair(
                    segment: segment.name, offset: tail.offset, length: Int64(torn.count),
                    blob: blob, reason: reason),
                actor: .system)
            var head = Head(seq: 0, hash: Event.genesisHash)
            for candidate in try store.segments().reversed() {
                if let found = try lastHead(of: candidate) {
                    head = found
                    break
                }
            }
            let (event, line) = try LedgerLine.seal(
                repair, seq: head.seq + 1, prev: head.hash, id: store.ambient.newID(EventID.self),
                at: store.ambient.now())
            try write([line])
            return Head(seq: event.seq, hash: event.hash)
        }
    }
}

/// Errors from `LedgerStore`.
public enum LedgerStoreError: Error, Hashable, Sendable {
    /// The last complete line fails its hash or envelope check. The ledger is read-only until
    /// a person runs `arya ledger verify` and decides.
    case chainBroken(segment: String, offset: Int64, problem: LineProblem)
}
