import AryaCore
import Foundation

extension WireRecord {
    /// The `run.adapter.event` payload for this record: `direction`, then `message` (the
    /// parsed line) or `raw` (a line that is not JSON), plus `source: "connection"` for lines
    /// the connection wrote on its own. Host and adapter sources are implied by `direction`.
    public var ledgerPayload: JSONValue {
        var members: [String: JSONValue] = ["direction": .string(direction.rawValue)]
        if let value = try? CanonicalJSON.decode(JSONValue.self, from: line) {
            members["message"] = value
        } else {
            members["raw"] = .string(String(decoding: line, as: UTF8.self))
        }
        if source == .connection { members["source"] = .string(source.rawValue) }
        return .object(members)
    }

    /// Rebuilds a record from a `run.adapter.event` payload, for ``ReplayAdapter``. The line is
    /// the canonical encoding of `message`, which is byte-identical to what was sent or read
    /// because both sides of a live connection write canonical JSON.
    public init?(ledgerPayload payload: JSONValue) {
        guard let direction = payload["direction"]?.stringValue.flatMap(WireDirection.init)
        else { return nil }
        let source = payload["source"]?.stringValue.flatMap(WireSource.init)
        if let message = payload["message"] {
            self.init(direction: direction, source: source, line: LineCodec.encodeJSON(message))
        } else if let raw = payload["raw"]?.stringValue {
            self.init(direction: direction, source: source, line: Data(raw.utf8))
        } else {
            return nil
        }
    }
}
