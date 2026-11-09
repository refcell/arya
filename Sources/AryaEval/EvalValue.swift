/// A JSON value used by replay comparison, scorers, and case results.
///
/// Objects keep keys in a dictionary; comparisons and paths visit keys in sorted order so every
/// report is deterministic. This type is local to `AryaEval` until `AryaCore` publishes a shared
/// JSON value.
public enum EvalValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([EvalValue])
    case object([String: EvalValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([EvalValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: EvalValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
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

    /// The member at `key` when this is an object, otherwise `nil`.
    public subscript(key: String) -> EvalValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }
}
