import AryaCore
import CryptoKit
import Foundation

/// The write and verify rule for one ledger line (decision 0012).
///
/// The writer encodes the event without `hash` as canonical JSON into bytes `B`, computes
/// `hash = hex(sha256(B))`, and writes `B` with its final `}` replaced by
/// `,"hash":"<hex>"}`. A verifier strips that fixed-length suffix, appends `}`, and hashes;
/// it never re-encodes.
public enum LedgerLine {
    /// `,"hash":"` + 64 hex digits + `"}`.
    public static let suffixLength = 9 + 64 + 2

    private static let suffixHead = Array(#","hash":""#.utf8)

    /// Seals a draft into an event and its line bytes, without the trailing newline.
    public static func seal(
        _ draft: EventDraft, seq: Int64, prev: String, id: EventID, at: Timestamp
    ) throws -> (event: Event, line: [UInt8]) {
        guard case .object = draft.payload else { throw LedgerError.payloadNotObject }
        // The payload sits one level inside the envelope; deeper lines could not be read back.
        guard JSONParser.nests(draft.payload, within: JSONParser.maxDepth - 1) else {
            throw LedgerError.payloadTooDeep
        }
        var fields: [String: JSONValue] = [
            "v": 1, "seq": .int(seq), "id": .string(id.rawValue), "at": .string(at.description),
            "actor": try CanonicalJSON.jsonValue(draft.actor),
            "type": .string(draft.type.rawValue), "payload": draft.payload, "prev": .string(prev),
        ]
        if let steward = draft.steward { fields["steward"] = .string(steward.rawValue) }
        if let run = draft.run { fields["run"] = .string(run.rawValue) }
        var body = [UInt8]()
        try CanonicalJSON.write(.object(fields), into: &body)
        let hash = hexSHA256(body)
        var line = body
        line.removeLast()
        line += suffixHead
        line += Array(hash.utf8)
        line += Array(#""}"#.utf8)
        let event = Event(
            v: 1, seq: seq, id: id, at: at, steward: draft.steward, run: draft.run,
            actor: draft.actor, type: draft.type, payload: draft.payload, prev: prev, hash: hash)
        return (event, line)
    }

    /// Checks the hash of one line (without its newline) and decodes it. Does not check
    /// `seq` or `prev` continuity; `LedgerVerifier` does.
    public static func open(_ line: some Collection<UInt8>) throws -> Event {
        if let event = try line.withContiguousStorageIfAvailable({ try open(buffer: $0) }) {
            return event
        }
        return try Array(line).withUnsafeBufferPointer { try open(buffer: $0) }
    }

    private static func open(buffer bytes: UnsafeBufferPointer<UInt8>) throws -> Event {
        guard bytes.count > suffixLength + 1 else { throw LineProblem.tooShort }
        let split = bytes.count - suffixLength
        guard hasHashSuffix(bytes, at: split) else { throw LineProblem.missingHashSuffix }
        var hasher = SHA256()
        hasher.update(
            bufferPointer: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: bytes[..<split])))
        hasher.update(data: closingBrace)
        let digest = hexDigest(hasher.finalize())
        let claimed = split + suffixHead.count
        var offset = 0
        while offset < 64 {
            guard digest[offset] == bytes[claimed + offset] else { throw LineProblem.hashMismatch }
            offset += 1
        }
        let event: Event
        do {
            event = try Event(envelope: JSONParser.parse(bytes))
        } catch let problem as JSONParseError {
            throw LineProblem.badEnvelope(problem.description)
        } catch let problem as EnvelopeProblem {
            throw LineProblem.badEnvelope(problem.field)
        }
        guard event.v == 1 else { throw LineProblem.badEnvelope("unsupported version") }
        guard case .object = event.payload else { throw LineProblem.badEnvelope("payload") }
        guard isHex64(event.prev) else { throw LineProblem.badEnvelope("prev") }
        return event
    }

    /// Whether `bytes` ends, from `split`, in `,"hash":"` + 64 lowercase hex digits + `"}`.
    private static func hasHashSuffix(_ bytes: UnsafeBufferPointer<UInt8>, at split: Int) -> Bool {
        // Index loops, not generic slice algorithms, which are slow in debug builds.
        let head = suffixHead
        var offset = 0
        while offset < head.count {
            guard bytes[split + offset] == head[offset] else { return false }
            offset += 1
        }
        while offset < head.count + 64 {
            guard isLowerHex(bytes[split + offset]) else { return false }
            offset += 1
        }
        return bytes[bytes.count - 2] == UInt8(ascii: "\"") && bytes[bytes.count - 1] == 125
    }

    private static func isHex64(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { utf8 in
            guard utf8.count == 64 else { return false }
            var offset = 0
            while offset < 64 {
                guard isLowerHex(utf8[offset]) else { return false }
                offset += 1
            }
            return true
        }
    }

    private static let closingBrace = Data([UInt8(ascii: "}")])

    /// Lowercase hex SHA-256.
    public static func hexSHA256(_ bytes: some Sequence<UInt8>) -> String {
        String(decoding: hexDigest(SHA256.hash(data: Data(bytes))), as: UTF8.self)
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        digest.withUnsafeBytes { raw in
            var index = 0
            while index < raw.count {
                out[2 * index] = hexDigit(raw[index] >> 4)
                out[2 * index + 1] = hexDigit(raw[index] & 15)
                index += 1
            }
        }
        return out
    }

    private static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? nibble + 48 : nibble + 87
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        byte &- 48 < 10 || byte &- 97 < 6
    }
}

/// Why one line failed to open.
public enum LineProblem: Error, Hashable, Sendable, CustomStringConvertible {
    case tooShort
    case missingHashSuffix
    case hashMismatch
    case badEnvelope(String)

    public var description: String {
        switch self {
        case .tooShort: return "line too short"
        case .missingHashSuffix: return "missing hash suffix"
        case .hashMismatch: return "hash mismatch"
        case .badEnvelope(let detail): return "bad envelope: \(detail)"
        }
    }
}

/// Ledger errors.
public enum LedgerError: Error, Hashable, Sendable {
    /// A draft's payload was not a JSON object.
    case payloadNotObject
    /// A draft's payload nests deeper than `JSONParser.maxDepth - 1` levels, so its line
    /// could not be read back.
    case payloadTooDeep
    /// `Event.payload(as:)` was asked for the wrong type.
    case payloadType(seq: Int64, expected: EventType, actual: EventType)
}
