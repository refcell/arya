import AryaCore
import Foundation

extension JSONValue {
    /// Converts any encodable value into a JSON value.
    init(encoding value: some Encodable) throws {
        self = try CanonicalJSON.jsonValue(value)
    }

    /// Decodes this JSON value as `type`.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try CanonicalJSON.decode(type, from: try CanonicalJSON.encode(self))
    }
}
