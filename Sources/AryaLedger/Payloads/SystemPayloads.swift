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
