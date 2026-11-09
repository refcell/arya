import Foundation

/// A JSON value as feature views see event payloads. Views read payloads through this type
/// until `AryaLedger` publishes typed payloads; see the app-views lane decisions.
enum FeatureJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FeatureJSON])
    case object([String: FeatureJSON])

    /// The member named `key`, or `nil` when this is not an object or has no such member.
    subscript(key: String) -> FeatureJSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [FeatureJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The string elements of an array, skipping anything else.
    var strings: [String] { array?.compactMap(\.string) ?? [] }

    /// Compact JSON with sorted keys, for code blocks and table cells.
    var compactText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return Self.format(value)
        case .string(let value): return Self.quote(value)
        case .array(let items): return "[" + items.map(\.compactText).joined(separator: ",") + "]"
        case .object(let members):
            let pairs = members.keys.sorted().map { key in
                Self.quote(key) + ":" + (members[key] ?? .null).compactText
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

extension FeatureJSON: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([FeatureJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: FeatureJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension FeatureJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: FeatureJSON...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }

    init(dictionaryLiteral elements: (String, FeatureJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
