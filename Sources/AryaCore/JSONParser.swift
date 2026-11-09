import Foundation

/// A byte-level JSON parser into `JSONValue`, much faster than `JSONDecoder` and built to give
/// the same value for every input `JSONDecoder` accepts.
///
/// Matching `JSONDecoder` (decoding `JSONValue`) means:
/// - Integers without a fraction or exponent are exact `int`s when they fit `Int64`, else
///   `double`s.
/// - Other numbers parse as `Double`. When that is integral and in `[-2^63, 2^63)` and the
///   decimal is an exact integer that fits, the result is that `int` (`1e2` is `100`, `0.1e1`
///   is `1`); a non-integral `Double` stays a `double`; infinite values are errors. The rare
///   token whose decimal has a fraction yet rounds to an integral `Double` (more digits than a
///   `Double` holds, never written by `CanonicalJSON`) is handed to `JSONDecoder` itself.
/// - A leading byte-order mark and one trailing comma after the last array element or object
///   member are accepted. On duplicate keys the first wins.
/// - Strings must be valid UTF-8 with no raw control characters; `\u` escapes must pair
///   surrogates.
///
/// Two deliberate differences: nesting deeper than `maxDepth` is an error, so recursion stays
/// well inside a secondary thread's 512 KiB stack; and a raw NUL byte is always an error,
/// where `JSONDecoder` accepts one next to a top-level number (`5\0`).
public enum JSONParser {
    /// The deepest nesting accepted (the top-level value is depth 1).
    public static let maxDepth = 128

    /// Parses one JSON document, surrounded by optional whitespace.
    public static func parse(_ bytes: some Collection<UInt8>) throws(JSONParseError) -> JSONValue {
        let result: Result<JSONValue, JSONParseError>? = bytes.withContiguousStorageIfAvailable {
            buffer in Result { () throws(JSONParseError) in try parse(buffer: buffer) }
        }
        if let result { return try result.get() }
        let copy = Array(bytes)
        return try copy.withUnsafeBufferPointer { buffer throws(JSONParseError) in
            try parse(buffer: buffer)
        }
    }

    /// Whether `value` nests at most `depth` arrays and objects deep, the measure `maxDepth`
    /// uses (scalars add nothing). Stops at the limit, so it recurses at most `depth` deep.
    public static func nests(_ value: JSONValue, within depth: Int) -> Bool {
        switch value {
        case .array(let items):
            return depth > 0 && items.allSatisfy { nests($0, within: depth - 1) }
        case .object(let members):
            return depth > 0 && members.values.allSatisfy { nests($0, within: depth - 1) }
        default: return true
        }
    }

    private static func parse(
        buffer: UnsafeBufferPointer<UInt8>
    ) throws(JSONParseError) -> JSONValue {
        var reader = JSONByteReader(bytes: buffer)
        if buffer.count >= 3, buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF {
            reader.index = 3
        }
        let value = try reader.value(depth: 0)
        reader.skipWhitespace()
        guard reader.index == buffer.count else { throw reader.error("trailing bytes") }
        return value
    }
}

/// Why `JSONParser` rejected its input, with the byte offset where it gave up.
public struct JSONParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public var offset: Int
    public var reason: String

    public init(offset: Int, reason: String) {
        self.offset = offset
        self.reason = reason
    }

    public var description: String { "invalid JSON at byte \(offset): \(reason)" }
}

private struct JSONByteReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    func error(_ reason: String) -> JSONParseError {
        JSONParseError(offset: index, reason: reason)
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 else { return }
            index += 1
        }
    }

    mutating func value(depth: Int) throws(JSONParseError) -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw error("unexpected end") }
        // Plain byte comparisons, not range patterns: debug builds run those through
        // generic code, and the ledger's tests read thousands of lines in debug.
        let byte = bytes[index]
        if byte == Byte.quote { return .string(try string()) }
        if byte == Byte.openBrace { return try object(depth: depth + 1) }
        if byte == Byte.openBracket { return try array(depth: depth + 1) }
        if byte == Byte.minus || isDigit(byte) { return try number() }
        if byte == 0x74 {  // t
            try literal("true")
            return .bool(true)
        }
        if byte == 0x66 {  // f
            try literal("false")
            return .bool(false)
        }
        if byte == 0x6E {  // n
            try literal("null")
            return .null
        }
        throw error("unexpected byte")
    }

    mutating func literal(_ word: StaticString) throws(JSONParseError) {
        let count = word.utf8CodeUnitCount
        guard bytes.count - index >= count else { throw error("bad literal") }
        let base = word.utf8Start
        var offset = 0
        while offset < count {
            guard bytes[index + offset] == base[offset] else { throw error("bad literal") }
            offset += 1
        }
        index += count
    }

    mutating func array(depth: Int) throws(JSONParseError) -> JSONValue {
        guard depth <= JSONParser.maxDepth else { throw error("too deep") }
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == Byte.closeBracket {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try value(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            let byte = bytes[index]
            index += 1
            if byte == Byte.closeBracket { return .array(items) }
            guard byte == Byte.comma else {
                throw JSONParseError(offset: index - 1, reason: "expected , or ]")
            }
            skipWhitespace()
            if index < bytes.count, bytes[index] == Byte.closeBracket {
                index += 1
                return .array(items)
            }
        }
    }

    mutating func object(depth: Int) throws(JSONParseError) -> JSONValue {
        guard depth <= JSONParser.maxDepth else { throw error("too deep") }
        index += 1
        var members: [String: JSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == Byte.closeBrace {
            index += 1
            return .object(members)
        }
        while true {
            guard index < bytes.count, bytes[index] == Byte.quote else {
                throw error("expected key")
            }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == Byte.colon else {
                throw error("expected :")
            }
            index += 1
            let member = try value(depth: depth)
            if members[key] == nil { members[key] = member }
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            let byte = bytes[index]
            index += 1
            if byte == Byte.closeBrace { return .object(members) }
            guard byte == Byte.comma else {
                throw JSONParseError(offset: index - 1, reason: "expected , or }")
            }
            skipWhitespace()
            if index < bytes.count, bytes[index] == Byte.closeBrace {
                index += 1
                return .object(members)
            }
        }
    }
}

/// ASCII bytes the parser compares against, as literals so debug builds compare directly.
enum Byte {
    static let quote: UInt8 = 0x22
    static let backslash: UInt8 = 0x5C
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D
    static let comma: UInt8 = 0x2C
    static let colon: UInt8 = 0x3A
    static let minus: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let zero: UInt8 = 0x30
    static let lowerE: UInt8 = 0x65
}

// MARK: Strings

extension JSONByteReader {
    /// Reads a string starting at its opening quote.
    mutating func string() throws(JSONParseError) -> String {
        index += 1
        let start = index
        var ascii = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Byte.quote {
                let run = UnsafeBufferPointer(rebasing: bytes[start..<index])
                index += 1
                if !ascii, !UTF8Check.isValid(run) {
                    throw JSONParseError(offset: start, reason: "invalid UTF-8")
                }
                return String(decoding: run, as: UTF8.self)
            }
            if byte == Byte.backslash { return try escapedString(from: start) }
            if byte < 0x20 { throw error("control character in string") }
            if byte >= 0x80 { ascii = false }
            index += 1
        }
        throw error("unterminated string")
    }

    /// Continues a string that holds escapes, copying its bytes so far.
    private mutating func escapedString(from start: Int) throws(JSONParseError) -> String {
        var out = Array(UnsafeBufferPointer(rebasing: bytes[start..<index]))
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Byte.quote {
                index += 1
                let valid = out.withUnsafeBufferPointer { UTF8Check.isValid($0) }
                guard valid else { throw JSONParseError(offset: start, reason: "invalid UTF-8") }
                return String(decoding: out, as: UTF8.self)
            }
            if byte < 0x20 { throw error("control character in string") }
            if byte != Byte.backslash {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case Byte.quote, UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"): appendUTF8(try unicodeEscape(), to: &out)
            default: throw error("bad escape")
            }
        }
        throw error("unterminated string")
    }

    /// Reads the hex digits after `\u`, pairing a high surrogate with the following low one.
    private mutating func unicodeEscape() throws(JSONParseError) -> UInt32 {
        let unit = try hex4()
        if (0xDC00...0xDFFF).contains(unit) { throw error("lone low surrogate") }
        guard (0xD800...0xDBFF).contains(unit) else { return unit }
        guard bytes.count - index >= 2, bytes[index] == UInt8(ascii: "\\"),
            bytes[index + 1] == UInt8(ascii: "u")
        else { throw error("lone high surrogate") }
        index += 2
        let low = try hex4()
        guard (0xDC00...0xDFFF).contains(low) else { throw error("bad low surrogate") }
        return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
    }

    private mutating func hex4() throws(JSONParseError) -> UInt32 {
        guard bytes.count - index >= 4 else { throw error("short \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw error("bad \\u escape")
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    private func appendUTF8(_ scalar: UInt32, to out: inout [UInt8]) {
        switch scalar {
        case 0..<0x80:
            out.append(UInt8(scalar))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | scalar >> 6))
            out.append(UInt8(0x80 | scalar & 0x3F))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | scalar >> 12))
            out.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            out.append(UInt8(0x80 | scalar & 0x3F))
        default:
            out.append(UInt8(0xF0 | scalar >> 18))
            out.append(UInt8(0x80 | scalar >> 12 & 0x3F))
            out.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            out.append(UInt8(0x80 | scalar & 0x3F))
        }
    }
}

/// Strict UTF-8 validation: no overlong forms, surrogates, or scalars above U+10FFFF.
enum UTF8Check {
    static func isValid(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            let count: Int
            var low: UInt8 = 0x80
            var high: UInt8 = 0xBF
            switch lead {
            case 0xC2...0xDF: count = 1
            case 0xE0: count = 2; low = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: count = 2
            case 0xED: count = 2; high = 0x9F
            case 0xF0: count = 3; low = 0x90
            case 0xF1...0xF3: count = 3
            case 0xF4: count = 3; high = 0x8F
            default: return false
            }
            guard bytes.count - index > count else { return false }
            let second = bytes[index + 1]
            guard second >= low, second <= high else { return false }
            for offset in stride(from: 2, through: count, by: 1)
            where bytes[index + offset] & 0xC0 != 0x80 {
                return false
            }
            index += count + 1
        }
        return true
    }
}

// MARK: Numbers

extension JSONByteReader {
    /// Reads a number token and classifies it as `int` or `double` (see `JSONParser`).
    mutating func number() throws(JSONParseError) -> JSONValue {
        let start = index
        let negative = bytes[index] == Byte.minus
        if negative { index += 1 }
        let intStart = index
        guard index < bytes.count, isDigit(bytes[index]) else { throw error("bad number") }
        if bytes[index] == Byte.zero {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let intEnd = index
        var fracEnd = index
        var exponent: Int64 = 0
        var plain = true
        if index < bytes.count, bytes[index] == Byte.dot {
            plain = false
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("bad fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            fracEnd = index
        }
        if index < bytes.count, bytes[index] | 0x20 == Byte.lowerE {
            plain = false
            exponent = try exponentValue()
        }
        if index < bytes.count, !isDelimiter(bytes[index]) { throw error("bad number") }
        let token = UnsafeBufferPointer(rebasing: bytes[start..<index])
        if plain, let exact = plainInteger(intStart..<intEnd, negative: negative) {
            return .int(exact)
        }
        guard let double = Double(String(decoding: token, as: UTF8.self)), double.isFinite else {
            throw JSONParseError(offset: start, reason: "number out of range")
        }
        if plain { return .double(double) }
        let digits = Digits(bytes: bytes, intRange: intStart..<intEnd, fracEnd: fracEnd)
        guard double == double.rounded(.towardZero), double >= -0x1p63, double < 0x1p63 else {
            return .double(double)
        }
        let part = digits.integerPart(exponent: exponent)
        if part.hasFraction { return try decoderNumber(token, at: start) }
        guard let magnitude = part.value else { return .double(double) }
        return .int(negative ? 0 &- magnitude : magnitude)
    }

    /// Asks `JSONDecoder` to classify one number token.
    private func decoderNumber(
        _ token: UnsafeBufferPointer<UInt8>, at start: Int
    ) throws(JSONParseError) -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(token)) else {
            throw JSONParseError(offset: start, reason: "number out of range")
        }
        return value
    }

    private mutating func exponentValue() throws(JSONParseError) -> Int64 {
        index += 1
        var sign: Int64 = 1
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == 45 {
            if bytes[index] == UInt8(ascii: "-") { sign = -1 }
            index += 1
        }
        guard index < bytes.count, isDigit(bytes[index]) else { throw error("bad exponent") }
        var value: Int64 = 0
        while index < bytes.count, isDigit(bytes[index]) {
            value = min(value * 10 + Int64(bytes[index] - UInt8(ascii: "0")), 1_000_000_000)
            index += 1
        }
        return sign * value
    }

    private func plainInteger(_ digits: Range<Int>, negative: Bool) -> Int64? {
        // 19 digits always fit in UInt64; longer runs overflow Int64 anyway.
        guard digits.count <= 19 else { return nil }
        var magnitude: UInt64 = 0
        var position = digits.lowerBound
        while position < digits.upperBound {
            magnitude = magnitude * 10 + UInt64(bytes[position] &- Byte.zero)
            position += 1
        }
        if negative {
            if magnitude == UInt64(Int64.max) + 1 { return Int64.min }
            return magnitude <= UInt64(Int64.max) ? -Int64(magnitude) : nil
        }
        return magnitude <= UInt64(Int64.max) ? Int64(magnitude) : nil
    }

    func isDigit(_ byte: UInt8) -> Bool { byte &- Byte.zero < 10 }

    private func isDelimiter(_ byte: UInt8) -> Bool {
        byte == Byte.comma || byte == Byte.closeBrace || byte == Byte.closeBracket
            || byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// The significant digits of a number token: its integer digits followed by its fraction.
private struct Digits {
    let bytes: UnsafeBufferPointer<UInt8>
    let intRange: Range<Int>
    let fracEnd: Int

    /// The integer part of `digits × 10^exponent` (nil when it does not fit a non-negative
    /// `Int64`), and whether any nonzero digit falls after the decimal point.
    func integerPart(exponent: Int64) -> (value: Int64?, hasFraction: Bool) {
        let fracStart = intRange.upperBound + 1
        let fracCount = fracEnd > intRange.upperBound ? fracEnd - fracStart : 0
        let total = Int64(intRange.count + fracCount)
        let point = Int64(intRange.count) + exponent
        var hasFraction = false
        var position = max(point, 0)
        while position < total {
            if digit(at: Int(position), fracStart: fracStart) != 0 { hasFraction = true }
            position += 1
        }
        var value: Int64? = 0
        position = 0
        while position < point, let current = value {
            let next = position < total ? digit(at: Int(position), fracStart: fracStart) : 0
            if position >= total, current == 0 { break }
            let (times, overflow1) = current.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times.addingReportingOverflow(next)
            value = overflow1 || overflow2 ? nil : sum
            position += 1
        }
        return (value, hasFraction)
    }

    private func digit(at offset: Int, fracStart: Int) -> Int64 {
        let at =
            offset < intRange.count
            ? intRange.lowerBound + offset : fracStart + offset - intRange.count
        return Int64(bytes[at] &- 48)
    }
}
