import Foundation

/// Checks the whole ledger in one pass: every line's envelope and hash, `seq` starting at 1
/// with no gaps, and each `prev` equal to the previous `hash` (decisions 0003, 0012). Reports
/// the first bad line. Takes no lock; run it on a quiet ledger or accept that a line being
/// appended right now may be reported as torn.
public struct LedgerVerifier: Sendable {
    public let reader: LedgerReader

    public init(home: URL) {
        reader = LedgerReader(home: home)
    }

    /// The verdict for the whole ledger.
    public func verify() throws -> LedgerVerification {
        var expectedSeq: Int64 = 1
        var prev = Event.genesisHash
        var count: Int64 = 0
        let segments = try reader.existingSegments()
        for (index, segment) in segments.enumerated() {
            var failure: LedgerVerification.Failure?
            try reader.scanLines(segment) { line, offset, number in
                guard failure == nil else { return }
                let at = LedgerVerification.Location(
                    segment: segment.name, line: number, offset: offset)
                let event: Event
                do {
                    event = try LedgerLine.open(line)
                } catch let problem as LineProblem {
                    failure = .init(location: at, issue: .line(problem))
                    return
                }
                if event.seq != expectedSeq {
                    failure = .init(
                        location: at, issue: .seqGap(expected: expectedSeq, found: event.seq))
                } else if event.prev != prev {
                    failure = .init(location: at, issue: .prevMismatch(seq: event.seq))
                } else {
                    expectedSeq += 1
                    prev = event.hash
                    count += 1
                }
            }
            if let failure {
                return LedgerVerification(
                    events: count, head: prev, segments: segments.count, failure: failure)
            }
            if let torn = try tornTail(segment, isNewest: index == segments.count - 1) {
                return LedgerVerification(
                    events: count, head: prev, segments: segments.count, failure: torn)
            }
        }
        return LedgerVerification(
            events: count, head: prev, segments: segments.count, failure: nil)
    }

    /// Bytes after the last newline: a torn line. Allowed in no segment; in the newest one the
    /// store repairs it on the next open.
    private func tornTail(_ segment: Segment, isNewest: Bool) throws
        -> LedgerVerification.Failure?
    {
        let fd = try FileIO.open(segment.url, O_RDONLY)
        defer { close(fd) }
        guard let tail = try SegmentTail.read(fd, name: segment.name), !tail.terminated else {
            return nil
        }
        var lines = 0
        try reader.scanLines(segment) { _, _, _ in lines += 1 }
        return .init(
            location: .init(segment: segment.name, line: lines + 1, offset: tail.offset),
            issue: .torn(repairable: isNewest))
    }
}

/// The result of `LedgerVerifier.verify()`.
public struct LedgerVerification: Hashable, Sendable {
    /// Events verified before the first failure (all of them when `ok`).
    public var events: Int64
    /// Hash of the last good event (the genesis hash for an empty ledger).
    public var head: String
    /// Segment files found, including any after the failure.
    public var segments: Int
    public var failure: Failure?

    public init(events: Int64, head: String, segments: Int, failure: Failure?) {
        self.events = events
        self.head = head
        self.segments = segments
        self.failure = failure
    }

    public var ok: Bool { failure == nil }

    /// The `seq` the first bad line should have had, or nil when the ledger verifies.
    public var firstBadSeq: Int64? { failure == nil ? nil : events + 1 }

    public struct Location: Hashable, Sendable, CustomStringConvertible {
        public var segment: String
        /// 1-based.
        public var line: Int
        public var offset: Int64

        public init(segment: String, line: Int, offset: Int64) {
            self.segment = segment
            self.line = line
            self.offset = offset
        }

        public var description: String { "\(segment):\(line)" }
    }

    public enum Issue: Hashable, Sendable, CustomStringConvertible {
        /// Bad hash or envelope.
        case line(LineProblem)
        case seqGap(expected: Int64, found: Int64)
        case prevMismatch(seq: Int64)
        /// A final line without a newline. Repairable when it is in the newest segment.
        case torn(repairable: Bool)

        public var description: String {
            switch self {
            case .line(let problem): return problem.description
            case .seqGap(let expected, let found): return "seq \(found), expected \(expected)"
            case .prevMismatch(let seq): return "seq \(seq): prev does not match previous hash"
            case .torn(let repairable):
                return repairable ? "torn final line (repaired on next open)" : "torn line"
            }
        }
    }

    public struct Failure: Hashable, Sendable, CustomStringConvertible {
        public var location: Location
        public var issue: Issue

        public init(location: Location, issue: Issue) {
            self.location = location
            self.issue = issue
        }

        public var description: String { "\(location): \(issue)" }
    }
}
