import Foundation

/// Canonical JSON: object keys sorted by their UTF-8 bytes, no insignificant whitespace, `/`
/// not escaped, non-ASCII text written as UTF-8, and only `"`, `\`, and control characters
/// escaped. Integers are written exactly; other numbers use Swift's shortest round-trip
/// form. The ledger hashes these bytes (decisions 0003 and 0012).
public enum CanonicalJSON {
    /// Encodes `value` canonically.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        Data(try bytes(value))
    }

    /// Encodes `value` canonically as bytes.
    public static func bytes<T: Encodable>(_ value: T) throws -> [UInt8] {
        var out = [UInt8]()
        try write(try jsonValue(value), into: &out)
        return out
    }

    /// Encodes `value` canonically as a string.
    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try bytes(value), as: UTF8.self)
    }

    /// Converts any `Encodable` into a `JSONValue`.
    public static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        if let json = value as? JSONValue { return json }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes `type` from JSON bytes with arya's standard decoder.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Appends the canonical bytes of `value` to `out`. Throws on a non-finite number.
    public static func write(_ value: JSONValue, into out: inout [UInt8]) throws {
        switch value {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let flag): out.append(contentsOf: (flag ? "true" : "false").utf8)
        case .int(let number): out.append(contentsOf: String(number).utf8)
        case .double(let number):
            guard number.isFinite else { throw CanonicalJSONError.nonFiniteNumber }
            out.append(contentsOf: formatDouble(number).utf8)
        case .string(let text): writeString(text, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            let keys = members.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                try write(members[key] ?? .null, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    /// Integral values within ±2^53 print without a fraction (`3`); others use Swift's
    /// shortest round-trip description (`0.95`, `1e-07`).
    static func formatDouble(_ number: Double) -> String {
        if number == number.rounded(), abs(number) <= 9_007_199_254_740_992 {
            return String(Int64(number))
        }
        return number.description
    }

    static func writeString(_ text: String, into out: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        out.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: [92, 34])
            case UInt8(ascii: "\\"): out.append(contentsOf: [92, 92])
            case 0x0A: out.append(contentsOf: [92, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [92, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [92, UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [92, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [92, UInt8(ascii: "f")])
            case 0..<0x20:
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 15)])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// Errors from `CanonicalJSON`.
public enum CanonicalJSONError: Error, Equatable {
    /// NaN or infinity, which JSON cannot represent.
    case nonFiniteNumber
}
