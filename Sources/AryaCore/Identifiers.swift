/// A typed identifier stored as a plain string with a fixed prefix, such as `st_triage` or
/// `run_01JC3F…`. Encodes and decodes as a bare JSON string; decoding rejects a value
/// that lacks the prefix or carries characters outside `[A-Za-z0-9_-]`.
public protocol PrefixedID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible
where RawValue == String {
    /// The prefix every value starts with, including its trailing underscore.
    static var prefix: String { get }
    /// Wraps `rawValue` without validating it. Prefer `init?(rawValue:)`.
    init(unchecked rawValue: String)
}

extension PrefixedID {
    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.init(unchecked: rawValue)
    }

    /// Makes an id from the part after the prefix, for example `StewardID(body: "triage")`.
    public init?(body: String) {
        self.init(rawValue: Self.prefix + body)
    }

    /// The part after the prefix.
    public var body: String { String(rawValue.dropFirst(Self.prefix.count)) }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    /// Whether `raw` has the prefix and a non-empty body of `[A-Za-z0-9_-]`.
    public static func isValid(_ raw: String) -> Bool {
        guard raw.hasPrefix(prefix), raw.utf8.count > prefix.utf8.count else { return false }
        return raw.utf8.dropFirst(prefix.utf8.count).allSatisfy(IDCharacters.isBodyByte)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard Self.isValid(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid \(Self.prefix) id")
        }
        self.init(unchecked: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum IDCharacters {
    static func isBodyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }
}

/// A steward, for example `st_triage`.
public struct StewardID: PrefixedID {
    public static let prefix = "st_"
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A run, for example `run_01JC3F8Z0000000000000000AB`.
public struct RunID: PrefixedID {
    public static let prefix = "run_"
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A ledger event.
public struct EventID: PrefixedID {
    public static let prefix = "ev_"
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// An approval request.
public struct ApprovalID: PrefixedID {
    public static let prefix = "ap_"
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A proposal to change a charter or routine.
public struct ProposalID: PrefixedID {
    public static let prefix = "prop_"
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A rehearsal of a steward on a casebook.
public struct RehearsalID: PrefixedID {
    public static let prefix = "reh_"
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A memory note.
public struct NoteID: PrefixedID {
    public static let prefix = "mem_"
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A case in a casebook, for example `case-0007`. Case ids come from imported data, so they
/// have no fixed prefix: any non-empty string of `[A-Za-z0-9_.:-]`.
public struct CaseID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func isValid(_ raw: String) -> Bool {
        !raw.isEmpty
            && raw.utf8.allSatisfy {
                IDCharacters.isBodyByte($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ":")
            }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard Self.isValid(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid case id")
        }
        rawValue = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
