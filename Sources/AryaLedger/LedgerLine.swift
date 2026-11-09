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
        let bytes = Array(line)
        guard bytes.count > suffixLength + 1 else { throw LineProblem.tooShort }
        let split = bytes.count - suffixLength
        let suffix = bytes[split...]
        guard suffix.starts(with: suffixHead), bytes.last == UInt8(ascii: "}"),
            bytes[bytes.count - 2] == UInt8(ascii: "\"")
        else { throw LineProblem.missingHashSuffix }
        let claimed = String(decoding: suffix.dropFirst(suffixHead.count).prefix(64), as: UTF8.self)
        guard claimed.utf8.allSatisfy(isLowerHex) else { throw LineProblem.missingHashSuffix }
        let body = bytes[..<split] + [UInt8(ascii: "}")]
        guard hexSHA256(body) == claimed else { throw LineProblem.hashMismatch }
        let event: Event
        do {
            event = try JSONDecoder().decode(Event.self, from: Data(bytes))
        } catch {
            throw LineProblem.badEnvelope(String(describing: error))
        }
        guard event.v == 1 else { throw LineProblem.badEnvelope("unsupported version") }
        guard case .object = event.payload else { throw LineProblem.badEnvelope("payload") }
        guard event.prev.utf8.count == 64, event.prev.utf8.allSatisfy(isLowerHex) else {
            throw LineProblem.badEnvelope("prev")
        }
        return event
    }

    /// Lowercase hex SHA-256.
    public static func hexSHA256(_ bytes: some Sequence<UInt8>) -> String {
        let digest = SHA256.hash(data: Data(bytes))
        let hex = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
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
    /// `Event.payload(as:)` was asked for the wrong type.
    case payloadType(seq: Int64, expected: EventType, actual: EventType)
}
