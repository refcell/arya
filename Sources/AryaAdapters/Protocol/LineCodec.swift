import AryaCore
import Foundation

/// Encodes and decodes JSON-RPC messages as single lines of UTF-8 JSON.
///
/// Encoding is canonical (`CanonicalJSON`), so the same message always produces the same
/// bytes, which keeps recordings diffable.
public enum LineCodec {
    /// The message as one line, `\n`-terminated.
    public static func encode(_ message: RPCMessage) -> Data {
        var data = encodeJSON(message.json)
        data.append(0x0A)
        return data
    }

    /// Canonical JSON bytes for a value (see `CanonicalJSON`), without a trailing newline.
    public static func encodeJSON(_ value: JSONValue) -> Data {
        var out = [UInt8]()
        // Only non-finite doubles fail, and JSON cannot carry them; write those as null.
        if (try? CanonicalJSON.write(value, into: &out)) == nil { out = Array("null".utf8) }
        return Data(out)
    }

    /// Decodes one line (with or without its trailing newline) into a message.
    ///
    /// Throws `-32700` for text that is not JSON and `-32600` for JSON that is not a
    /// JSON-RPC 2.0 message.
    public static func decode(_ line: Data) throws(RPCError) -> RPCMessage {
        var bytes = line
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        } catch {
            throw RPCError(code: RPCErrorCode.parseError, message: "stdout line is not JSON")
        }
        return try RPCMessage(json: value)
    }
}

/// Splits a byte stream into `\n`-terminated lines.
public struct LineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends bytes and returns every complete line, without its newline.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<index]))
            buffer = Data(buffer[buffer.index(after: index)...])
        }
        return lines
    }

    /// The bytes after the last newline, returned once the stream has ended.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}
