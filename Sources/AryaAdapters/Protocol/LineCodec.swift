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
///
/// A line longer than `maxLineBytes` is cut to its first `maxLineBytes` bytes and the rest,
/// up to the next newline, is dropped. A cut JSON-RPC line no longer decodes, so a runaway
/// adapter shows up as a protocol error instead of exhausting memory.
public struct LineSplitter: Sendable {
    /// The default cap: 8 MiB.
    public static let defaultMaxLineBytes = 8 << 20

    public let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false

    public init(maxLineBytes: Int = LineSplitter.defaultMaxLineBytes) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// Appends bytes and returns every complete line, without its newline.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if discarding {
                discarding = false
            } else {
                lines.append(capped(buffer[start..<newline]))
            }
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        if discarding {
            buffer = Data()
        } else if buffer.count > maxLineBytes {
            lines.append(capped(buffer[...]))
            buffer = Data()
            discarding = true
        }
        return lines
    }

    /// The bytes after the last newline, returned once the stream has ended.
    public mutating func finish() -> Data? {
        defer {
            buffer = Data()
            discarding = false
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func capped(_ bytes: Data.SubSequence) -> Data {
        Data(bytes.prefix(maxLineBytes))
    }
}
