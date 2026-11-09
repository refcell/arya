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
    ///
    /// A ledger whose first live event is past `seq` 1 (compacted) must hold a trusted
    /// `system.checkpoint` that covers the event before it (`SystemCheckpoint.anchors`): with
    /// `through` there and `head` equal to the first live `prev`, or with a listed segment
    /// ending there and a live `through` whose head matches. Otherwise it fails as
    /// `unanchored`. Every checkpoint must be signed by a
    /// trusted key (`Checkpoints.trustedRing()`) and match the live events and segments it
    /// names.
    public func verify() throws -> LedgerVerification {
        var pass = Pass()
        let segments = try reader.existingSegments()
        for (index, segment) in segments.enumerated() {
            try reader.scanLines(segment) { line, offset, number in
                guard pass.failure == nil else { return }
                pass.check(
                    line, at: .init(segment: segment.name, line: number, offset: offset))
            }
            if pass.failure == nil {
                pass.failure = try tornTail(segment, isNewest: index == segments.count - 1)
            }
            if pass.failure != nil { break }
        }
        if pass.failure == nil { pass.failure = try checkpointFailure(pass) }
        return LedgerVerification(
            events: pass.count, head: pass.prev, segments: segments.count,
            failure: pass.failure, firstSeq: pass.firstSeq)
    }

    /// State of the one verify pass.
    private struct Pass {
        var expectedSeq: Int64 = 1
        var prev = Event.genesisHash
        var count: Int64 = 0
        var firstSeq: Int64 = 1
        /// Where the first live event sits when it is past `seq` 1.
        var anchor: LedgerVerification.Location?
        /// The first live event's `prev`, which the anchoring checkpoint's `head` must equal.
        var anchorPrev = Event.genesisHash
        var ring = KeyRing()
        var checkpoints: [(seq: Int64, at: LedgerVerification.Location, value: SystemCheckpoint)] =
            []
        var failure: LedgerVerification.Failure?

        mutating func check(_ line: ArraySlice<UInt8>, at location: LedgerVerification.Location) {
            let event: Event
            do {
                event = try LedgerLine.open(line)
            } catch let problem as LineProblem {
                failure = .init(location: location, issue: .line(problem))
                return
            } catch {
                failure = .init(location: location, issue: .line(.badEnvelope("\(error)")))
                return
            }
            if count == 0, event.seq > 1 {
                // A compacted ledger starts mid-chain; the anchor is checked after the pass.
                expectedSeq = event.seq
                prev = event.prev
                anchorPrev = event.prev
                firstSeq = event.seq
                anchor = location
            }
            if event.seq != expectedSeq {
                failure = .init(
                    location: location, issue: .seqGap(expected: expectedSeq, found: event.seq))
                return
            }
            if event.prev != prev {
                failure = .init(location: location, issue: .prevMismatch(seq: event.seq))
                return
            }
            if event.type == .systemCheckpoint {
                guard let value = try? event.payload(as: SystemCheckpoint.self) else {
                    failure = .init(
                        location: location, issue: .badCheckpoint(seq: event.seq, .malformed))
                    return
                }
                checkpoints.append((event.seq, location, value))
            }
            try? ring.apply(event)
            expectedSeq += 1
            prev = event.hash
            count += 1
        }
    }

    /// After a clean pass: checkpoint heads and segment digests, then the anchor.
    private func checkpointFailure(_ pass: Pass) throws -> LedgerVerification.Failure? {
        let checker = Checkpoints(home: reader.directory.deletingLastPathComponent())
        var ring = pass.ring
        if pass.anchor != nil,
            let anchor = pass.checkpoints.first(where: { $0.value.anchors(firstSeq: pass.firstSeq) }
            )
        {
            ring.trust(anchor.value.keys)
        }
        var anchored = false
        for checkpoint in pass.checkpoints {
            if let problem = try checker.check(checkpoint.value, ring: ring) {
                return .init(
                    location: checkpoint.at, issue: .badCheckpoint(seq: checkpoint.seq, problem))
            }
            if pass.anchor != nil, checkpoint.value.anchors(firstSeq: pass.firstSeq) {
                // A `through` still live had its head checked above.
                guard
                    checkpoint.value.through >= pass.firstSeq
                        || checkpoint.value.head == pass.anchorPrev
                else {
                    return .init(
                        location: checkpoint.at,
                        issue: .badCheckpoint(seq: checkpoint.seq, .headMismatch))
                }
                anchored = true
            }
        }
        if let anchor = pass.anchor, !anchored {
            return .init(location: anchor, issue: .unanchored(first: pass.firstSeq))
        }
        return nil
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
    /// The first live `seq`: 1, or more on a compacted ledger.
    public var firstSeq: Int64

    public init(
        events: Int64, head: String, segments: Int, failure: Failure?, firstSeq: Int64 = 1
    ) {
        self.events = events
        self.head = head
        self.segments = segments
        self.failure = failure
        self.firstSeq = firstSeq
    }

    public var ok: Bool { failure == nil }

    /// The `seq` the first bad line should have had, or nil when the ledger verifies.
    public var firstBadSeq: Int64? {
        switch failure?.issue {
        case nil: return nil
        case .badCheckpoint(let seq, _)?: return seq
        case .unanchored(let first)?: return first
        default: return firstSeq + events
        }
    }

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
        /// A `system.checkpoint` that is untrusted or does not match the ledger.
        case badCheckpoint(seq: Int64, CheckpointProblem)
        /// The ledger starts at `first` > 1 with no trusted checkpoint through `first - 1`.
        case unanchored(first: Int64)

        public var description: String {
            switch self {
            case .line(let problem): return problem.description
            case .seqGap(let expected, let found): return "seq \(found), expected \(expected)"
            case .prevMismatch(let seq): return "seq \(seq): prev does not match previous hash"
            case .torn(let repairable):
                return repairable ? "torn final line (repaired on next open)" : "torn line"
            case .badCheckpoint(_, let problem): return problem.description
            case .unanchored(let first):
                return "starts at seq \(first) with no signed checkpoint through seq \(first - 1)"
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
