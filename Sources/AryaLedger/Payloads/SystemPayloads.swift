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
