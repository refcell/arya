import AryaCore

/// `env.read`: ambient readings an envelope does not already carry, served back by
/// `Ambient.recorded` in replay.
public struct EnvRead: EventPayload {
    public static let type = EventType.envRead
    public var v: Int
    public var readings: [AmbientReading]

    public init(readings: [AmbientReading]) {
        v = 1
        self.readings = readings
    }

    private enum CodingKeys: String, CodingKey { case v, readings }
}

/// `system.repair`: a torn final line was moved to a blob and truncated away.
public struct SystemRepair: EventPayload {
    public static let type = EventType.systemRepair
    public var v: Int
    /// Segment file name, for example `000003.jsonl`.
    public var segment: String
    /// Byte offset where the torn line started (the new segment length).
    public var offset: Int64
    /// Number of bytes removed.
    public var length: Int64
    /// SHA-256 of the removed bytes, the key of the blob holding them.
    public var blob: String
    public var reason: String

    public init(segment: String, offset: Int64, length: Int64, blob: String, reason: String) {
        v = 1
        self.segment = segment
        self.offset = offset
        self.length = length
        self.blob = blob
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case v, segment, offset, length, blob, reason }
}

/// `system.started`: a process opened the home for writing.
public struct SystemStarted: EventPayload {
    public static let type = EventType.systemStarted
    public var v: Int
    /// `cli`, `app`, `serve`, `test`, …
    public var process: String
    public var version: String

    public init(process: String, version: String) {
        v = 1
        self.process = process
        self.version = version
    }

    private enum CodingKeys: String, CodingKey { case v, process, version }
}

/// `system.key.added`: a checkpoint signing key's public half, recorded once. The first key
/// stands alone; a rotation names the key it `replaces` and carries that key's `signature`
/// over the canonical JSON of this payload without `signature`.
public struct SystemKeyAdded: EventPayload {
    public static let type = EventType.systemKeyAdded
    public var v: Int
    /// `key_` + the first 16 hex digits of the SHA-256 of the raw public key.
    public var key: String
    /// Always `ed25519`.
    public var algorithm: String
    /// Base64 of the 32-byte raw public key.
    public var publicKey: String
    /// The key this one rotates out, if any.
    public var replaces: String?
    /// Base64 Ed25519 signature by `replaces`; nil for the first key.
    public var signature: String?

    public init(
        key: String, publicKey: String, replaces: String? = nil, signature: String? = nil
    ) {
        v = 1
        self.key = key
        algorithm = "ed25519"
        self.publicKey = publicKey
        self.replaces = replaces
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case v, key, algorithm, publicKey, replaces, signature
    }
}

/// `system.checkpoint`: the ledger's state at `through`, signed by a recorded checkpoint key
/// (ARCHITECTURE.md, "Signed checkpoints and compaction"). The signature covers the canonical
/// JSON of this payload without `signature`.
public struct SystemCheckpoint: EventPayload {
    public static let type = EventType.systemCheckpoint
    public var v: Int
    /// The last `seq` covered.
    public var through: Int64
    /// The `hash` of the event at `through`.
    public var head: String
    /// Events in the history through `through`; equal to `through`, since `seq` starts at 1
    /// with no gaps.
    public var events: Int64
    /// Every closed segment wholly at or before `through`, oldest first.
    public var segments: [CheckpointSegment]
    /// Projection cache name to the SHA-256 of its canonical value at `through`.
    public var projections: [String: String]
    /// Every trusted key id to its base64 raw public key, so a compacted ledger whose
    /// `system.key.added` events were archived can still check this checkpoint.
    public var keys: [String: String]
    /// The signing key's id.
    public var key: String
    /// Base64 Ed25519 signature.
    public var signature: String

    public init(
        through: Int64, head: String, segments: [CheckpointSegment],
        projections: [String: String] = [:], keys: [String: String] = [:], key: String,
        signature: String = ""
    ) {
        v = 1
        self.through = through
        self.head = head
        events = through
        self.segments = segments
        self.projections = projections
        self.keys = keys
        self.key = key
        self.signature = signature
    }

    /// Whether this checkpoint can anchor a ledger whose first live event is `firstSeq`: it
    /// covers the event before it, either exactly (`through`) or as the end of a listed
    /// segment while `through` is still live.
    public func anchors(firstSeq: Int64) -> Bool {
        let cut = firstSeq - 1
        return through == cut || (through > cut && segments.contains { $0.last == cut })
    }

    /// The bytes the signature covers: the canonical payload without `signature`.
    public func signingBytes() throws -> [UInt8] {
        guard case .object(var fields) = try CanonicalJSON.jsonValue(self) else { return [] }
        fields["signature"] = nil
        var out = [UInt8]()
        try CanonicalJSON.write(.object(fields), into: &out)
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case v, through, head, events, segments, projections, keys, key, signature
    }
}

/// One closed segment listed by a checkpoint.
public struct CheckpointSegment: Hashable, Sendable, Codable {
    /// File name, for example `000001.jsonl`.
    public var name: String
    /// Lowercase hex SHA-256 of the whole file.
    public var sha256: String
    public var first: Int64
    public var last: Int64

    public init(name: String, sha256: String, first: Int64, last: Int64) {
        self.name = name
        self.sha256 = sha256
        self.first = first
        self.last = last
    }

    private enum CodingKeys: String, CodingKey { case name, sha256, first, last }
}
