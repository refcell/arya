import AryaCore
import Foundation

/// Paths and loaders for files under `Tests/AryaAdaptersTests/Fixtures`.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// The non-empty lines of a JSON Lines fixture, each decoded as a JSON value.
    static func jsonLines(_ name: String) throws -> [JSONValue] {
        let text = String(decoding: try data(name), as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        }
    }
}
