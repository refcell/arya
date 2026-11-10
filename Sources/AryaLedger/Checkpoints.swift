import AryaCore
import CryptoKit
import Foundation

/// Builds, records, and checks `system.checkpoint` events (ARCHITECTURE.md, "Signed
/// checkpoints and compaction"). A checkpoint takes no clock or randomness of its own: the
/// same ledger and key give the same payload; only the Ed25519 signature bytes vary.
public struct Checkpoints: Sendable {
    public let reader: LedgerReader

    public init(home: URL) { reader = LedgerReader(home: home) }

    /// A signed checkpoint through `through` (the newest event when nil).
    public func build(
        through: Int64? = nil, projections: [String: String] = [:], signer: CheckpointSigner
    ) throws -> SystemCheckpoint {
        let segments = try reader.existingSegments()
        guard let newest = segments.last, let last = try reader.lastEvent(of: newest) else {
            throw CheckpointError.emptyLedger
        }
        let through = through ?? last.seq
        guard through <= last.seq, let head = try reader.event(at: through) else {
            throw CheckpointError.outOfRange(through)
        }
        var listed: [CheckpointSegment] = []
        for segment in segments.dropLast() {
            guard let first = try reader.firstEvent(of: segment),
                let end = try reader.lastEvent(of: segment), end.seq <= through
            else { break }
            listed.append(
                CheckpointSegment(
                    name: segment.name, sha256: try reader.sha256(of: segment), first: first.seq,
                    last: end.seq))
        }
        var payload = SystemCheckpoint(
            through: through, head: head.hash, segments: listed, projections: projections,
            keys: try trustedRing().carried, key: signer.id)
        payload.signature = try signer.sign(payload.signingBytes())
        return payload
    }

    /// Builds a checkpoint and appends it as a `system` event. The signer must already be on
    /// the ledger (`CheckpointKeys.ensure`). With `caches`, every cache file in `cache/` that
    /// is exactly at `through` (the head by default) adds its value's digest to
    /// `projections` and is kept as a seed in `archive/seeds/<through>/`, so a compacted
    /// ledger can restore that projection (`ProjectionCache.current`). Bring the caches
    /// current first.
    @discardableResult
    public func record(
        store: LedgerStore, through: Int64? = nil, projections: [String: String] = [:],
        signer: CheckpointSigner, caches: ProjectionCache? = nil
    ) throws -> Event {
        guard try trustedRing().keys[signer.id] != nil else { throw CheckpointError.keyNotRecorded }
        var digests = projections
        var seeds: [String: [UInt8]] = [:]
        if let caches, let target = try through ?? headSeq(),
            let head = try reader.event(at: target)
        {
            for file in try caches.files(at: head) {
                digests[file.name] = file.digest
                seeds[file.name] = file.bytes
            }
        }
        let payload = try build(through: through, projections: digests, signer: signer)
        if !seeds.isEmpty {
            let dir = seedDirectory(payload.through)
            try FileIO.makeDirectory(dir.deletingLastPathComponent())
            try FileIO.makeDirectory(dir)
            for (name, bytes) in seeds {
                try FileIO.atomicWrite(Data(bytes), to: dir.appendingPathComponent(name + ".json"))
            }
        }
        return try store.append(EventDraft(payload, actor: .system))
    }

    /// `archive/seeds/<through>/`.
    func seedDirectory(_ through: Int64) -> URL {
        reader.directory.deletingLastPathComponent()
            .appendingPathComponent("archive/seeds", isDirectory: true)
            .appendingPathComponent(String(through), isDirectory: true)
    }

    /// Lowercase hex SHA-256 of a projection value's canonical JSON, as `projections` holds.
    public static func digest(_ value: JSONValue) throws -> String {
        var bytes = [UInt8]()
        try CanonicalJSON.write(value, into: &bytes)
        return LedgerLine.hexSHA256(bytes)
    }

    private func headSeq() throws -> Int64? { try reader.headSeq() }

    /// The keys this ledger trusts: every live `system.key.added`, plus, on a compacted
    /// ledger, the keys carried by its anchoring checkpoint (the first one that
    /// `anchors(firstSeq:)` the first live event). `LedgerVerifier` applies the same rule.
    public func trustedRing() throws -> KeyRing {
        var ring = try KeyRing.read(reader)
        guard let first = try reader.existingSegments().first,
            let firstEvent = try reader.firstEvent(of: first), firstEvent.seq > 1
        else { return ring }
        var anchor: SystemCheckpoint?
        do {
            try reader.forEach(LedgerFilter(types: [.systemCheckpoint])) { event in
                guard let value = try? event.payload(as: SystemCheckpoint.self),
                    value.anchors(firstSeq: firstEvent.seq)
                else { return }
                anchor = value
                throw FoundEvent()
            }
        } catch is FoundEvent {}
        if let anchor { ring.trust(anchor.keys) }
        return ring
    }

    /// Whether `checkpoint` is signed by a key `ring` trusts.
    public static func checkSignature(_ checkpoint: SystemCheckpoint, ring: KeyRing)
        -> CheckpointProblem?
    {
        guard checkpoint.v == 1, checkpoint.events == checkpoint.through else {
            return .malformed
        }
        guard let key = ring.publicKey(checkpoint.key) else { return .unknownKey(checkpoint.key) }
        guard let signature = Data(base64Encoded: checkpoint.signature),
            let bytes = try? checkpoint.signingBytes(),
            key.isValidSignature(signature, for: Data(bytes))
        else { return .badSignature }
        return nil
    }

    /// Checks `checkpoint` against this ledger: its signature, the head at `through` when
    /// that event is still live, and every listed segment whose file is still live. Events
    /// and segments no longer live (compacted away) are not judged here.
    public func check(_ checkpoint: SystemCheckpoint, ring: KeyRing) throws -> CheckpointProblem? {
        if let problem = Self.checkSignature(checkpoint, ring: ring) { return problem }
        if let event = try reader.event(at: checkpoint.through), event.hash != checkpoint.head {
            return .headMismatch
        }
        let live = Dictionary(
            try reader.existingSegments().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for listed in checkpoint.segments {
            guard let segment = live[listed.name] else { continue }
            if try reader.sha256(of: segment) != listed.sha256 {
                return .segmentMismatch(listed.name)
            }
        }
        return nil
    }
}

/// Why a checkpoint is not trusted.
public enum CheckpointProblem: Hashable, Sendable, CustomStringConvertible {
    /// Wrong version, or `events` differs from `through`.
    case malformed
    /// Signed by a key the ledger does not trust.
    case unknownKey(String)
    case badSignature
    /// The event at `through` has another hash.
    case headMismatch
    /// A listed segment's file has other bytes.
    case segmentMismatch(String)

    public var description: String {
        switch self {
        case .malformed: return "malformed checkpoint"
        case .unknownKey(let key): return "checkpoint signed by unknown key \(key)"
        case .badSignature: return "checkpoint signature does not verify"
        case .headMismatch: return "checkpoint head does not match the ledger"
        case .segmentMismatch(let name): return "checkpoint digest for \(name) does not match"
        }
    }
}

/// Checkpoint build failures.
public enum CheckpointError: Error, Hashable, Sendable {
    case emptyLedger
    /// No live event has this `seq`.
    case outOfRange(Int64)
    /// The signer has no `system.key.added` on the ledger.
    case keyNotRecorded
}

extension LedgerReader {
    /// The event with this `seq`, if live.
    func event(at seq: Int64) throws -> Event? {
        guard seq >= 1 else { return nil }
        var found: Event?
        do {
            try forEach(from: seq) { event in
                if event.seq == seq { found = event }
                throw FoundEvent()
            }
        } catch is FoundEvent {}
        return found
    }

    /// The last complete line's event; nil for an empty segment.
    func lastEvent(of segment: Segment) throws -> Event? {
        let fd = try FileIO.open(segment.url, O_RDONLY)
        defer { close(fd) }
        guard let tail = try SegmentTail.read(fd, name: segment.name) else { return nil }
        if tail.terminated { return try open(tail.line, segment: segment, offset: tail.offset) }
        // A torn final line: the last complete one comes before it.
        var last: Event?
        try scan(segment, openSealed: false) { event, _, _ in last = event }
        return last
    }

    /// Lowercase hex SHA-256 of a segment file, read in 1 MiB chunks.
    func sha256(of segment: Segment) throws -> String {
        let fd = try FileIO.open(segment.url, O_RDONLY)
        defer { close(fd) }
        let size = try FileIO.size(fd, name: segment.name)
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < size {
            let chunk = try FileIO.read(
                fd, at: offset, count: Int(min(1 << 20, size - offset)), name: segment.name)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            offset += Int64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func open(_ line: [UInt8], segment: Segment, offset: Int64) throws -> Event {
        do {
            return try LedgerLine.open(line)
        } catch let problem as LineProblem {
            // The line number is unknown without a scan; 0 marks "the last line".
            throw LedgerReadError(segment: segment.name, line: 0, offset: offset, problem: problem)
        }
    }
}

private struct FoundEvent: Error {}
