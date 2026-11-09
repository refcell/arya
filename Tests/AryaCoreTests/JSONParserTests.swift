import Foundation
import Testing

@testable import AryaCore

/// `JSONParser` must give exactly what `JSONDecoder` gives for `JSONValue`: the same value
/// for every accepted input and a rejection for every rejected one.
private func decoderValue(_ bytes: [UInt8]) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(bytes))
}

private func parserValue(_ bytes: [UInt8]) -> JSONValue? {
    try? JSONParser.parse(bytes)
}

private func expectSameAsDecoder(
    _ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation
) {
    let expected = decoderValue(bytes)
    let actual = parserValue(bytes)
    #expect(
        actual == expected, "input: \(bytes.map { String($0, radix: 16) })",
        sourceLocation: sourceLocation)
}

/// Inputs where `JSONDecoder`'s choices are easy to get wrong: number classification, escapes,
/// UTF-8, leniency, and malformed documents.
private let corpus: [String] = [
    "null", "true", "false", "nul", "tru", "0", "-0", "1", "-1", "01", "-01", "1.", ".5", "+1",
    "-", "1e", "1E", "1e+", "1.e5", "1.0", "-0.0", "1e2", "1E2", "1E+2", "1e-2", "2.5E-1",
    "0.5", "5e-1", "0.1e1", "1.5e3", "100e-2", "1.0e0", "0e0", "-0e0", "-0.0e5", "1e400",
    "-1e400", "1e-400", "4.9e-324", "1e1000000000000", "1e-1000000000000", "0e1000000000000",
    "9223372036854775807", "9223372036854775808", "-9223372036854775808",
    "-9223372036854775809", "12345678901234567890123", "9007199254740993",
    "9007199254740993.0", "9007199254740993.00", "9007199254740993.01", "9007199254740993e0",
    "-9007199254740993.0", "90071992547409930e-1", "9223372036854775807.0",
    "-9223372036854775807.0", "-9223372036854775808.0", "-9223372036854775808e0",
    "9223372036854775806.0", "9223372036854775295.0", "9223372036854774784e0",
    "1.00000000000000000001", "123456789012345678901234567890e-10", "1e+16",
    "9.223372036854776e+18", "-9.223372036854776e+18", "1.7976931348623157e+308", "123abc",
    #""""#, #""a""#, #""\/""#, #""\x""#, #""\U0041""#, #""\u0000""#, #""\u00e9""#,
    #""\u00G0""#, #""\ud83d\ude00""#, #""\ud800""#, #""\uD83D""#, #""\uDE00""#,
    #""\ud83d\u0041""#, #""\ud83d""#, #""a\"b\\c\nd\re\tf\bg\fh""#, "\"a\tb\"", "\"\u{7f}\"",
    "\"é😀中\"", "\"unterminated", "[]", "{}", "[1,]", "{\"a\":1,}", "[,]", "{,}", "[1,,2]",
    "[1 2]", "{\"a\" 1}", "{\"a\":1 \"b\":2}", "{a:1}", "'a'", "NaN", "[1]//c", "/*c*/1",
    "{\"a\":[1,],}", " \t\r\n1 ", "\u{0c}1", "1 2", "{\"a\":1,\"a\":2}",
    "[\"\\u00e9\",\"e\\u0301\"]", "{\"\\u00e9\":1,\"e\\u0301\":2}", "{\"b\":{\"c\":[true,null]}}",
    "[[[[[]]]]]", "{\"\":\"\"}", "[1.5,-2,\"x\",{\"k\":[]}]",
]

@Test func parserMatchesDecoderOnTheCorpus() {
    for text in corpus { expectSameAsDecoder(Array(text.utf8)) }
}

@Test func parserMatchesDecoderOnInvalidUTF8AndBOM() {
    let cases: [[UInt8]] = [
        [0x22, 0xFF, 0x22], [0x22, 0xC0, 0x80, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22],
        [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22], [0x22, 0xE2, 0x82, 0x22], [0x22, 0xC3, 0xA9, 0x22],
        [0xEF, 0xBB, 0xBF, 0x31], [0xEF, 0xBB, 0xBF], [0x5B, 0x31, 0x5D, 0x00],
    ]
    for bytes in cases { expectSameAsDecoder(bytes) }
    for bytes: [UInt8] in [[0x35, 0x00], [0x00, 0x35]] { #expect(parserValue(bytes) == nil) }
}

@Test func parserMatchesDecoderOnFixtures() throws {
    let names = [
        "canonical-input.json", "canonical-output.json", "case-0007.json",
        "case-0007.canonical.json", "charter-triage.json", "charter-triage.canonical.json",
    ]
    for name in names {
        let bytes = Array(try fixture(name))
        #expect(parserValue(bytes) != nil, "\(name)")
        expectSameAsDecoder(bytes)
    }
}

@Test func parserReportsWhereItStopped() {
    #expect(throws: JSONParseError(offset: 4, reason: "expected , or ]")) {
        try JSONParser.parse(Array("[1,2}".utf8))
    }
    let deep =
        Array(repeating: UInt8(ascii: "["), count: JSONParser.maxDepth + 1)
        + Array(repeating: UInt8(ascii: "]"), count: JSONParser.maxDepth + 1)
    #expect(throws: JSONParseError.self) { try JSONParser.parse(deep) }
    let ok =
        Array(repeating: UInt8(ascii: "["), count: JSONParser.maxDepth)
        + Array(repeating: UInt8(ascii: "]"), count: JSONParser.maxDepth)
    #expect(throws: Never.self) { try JSONParser.parse(ok) }
    let nested: JSONValue = [[["x"]]]
    #expect(JSONParser.nests(nested, within: 3))
    #expect(!JSONParser.nests(nested, within: 2))
    #expect(JSONParser.nests(1, within: 0))
}

@Test func parserAcceptsAnyContiguousOrNotCollection() throws {
    let text = #"{"a":[1,2.5,"x"]}"#
    let expected: JSONValue = ["a": [1, 2.5, "x"]]
    #expect(try JSONParser.parse(Array(text.utf8)) == expected)
    #expect(try JSONParser.parse(Data(text.utf8)) == expected)
    #expect(try JSONParser.parse(text.utf8) == expected)
    #expect(try JSONParser.parse(Array(text.utf8)[...]) == expected)
}

// MARK: Fuzzing

/// Iterations per fuzz test; raise with `ARYA_FUZZ_ITERATIONS` to search longer locally.
private let fuzzIterations =
    Int(ProcessInfo.processInfo.environment["ARYA_FUZZ_ITERATIONS"] ?? "") ?? 1500

@Test func randomValuesRoundTripLikeTheDecoder() throws {
    var rng = SeededGenerator(0xA11CE)
    let pretty = JSONEncoder()
    pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
    for _ in 0..<fuzzIterations {
        let value = RandomJSON.value(depth: 0, using: &rng)
        var canonical = [UInt8]()
        try CanonicalJSON.write(value, into: &canonical)
        for bytes in [canonical, Array(try pretty.encode(value))] {
            let parsed = try JSONParser.parse(bytes)
            #expect(parsed == decoderValue(bytes))
            var again = [UInt8]()
            try CanonicalJSON.write(parsed, into: &again)
            var viaDecoder = [UInt8]()
            try CanonicalJSON.write(decoderValue(bytes) ?? .null, into: &viaDecoder)
            #expect(again == viaDecoder)
        }
    }
}

@Test func mutatedDocumentsAreJudgedLikeTheDecoder() throws {
    var rng = SeededGenerator(0xBADC0DE)
    for _ in 0..<fuzzIterations {
        var bytes = [UInt8]()
        try CanonicalJSON.write(RandomJSON.value(depth: 0, using: &rng), into: &bytes)
        for _ in 0...Int.random(in: 0..<3, using: &rng) {
            RandomJSON.mutate(&bytes, using: &rng)
        }
        if bytes.contains(0) {
            // A raw NUL is never JSON; the parser rejects it even where JSONDecoder does not.
            #expect(parserValue(bytes) == nil)
        } else {
            expectSameAsDecoder(bytes)
        }
    }
}

/// Seeded random JSON values and byte mutations aimed at the parser's edge cases.
private enum RandomJSON {
    static let scalars: [Unicode.Scalar] = [
        "a", "Z", "0", " ", "\"", "\\", "/", "\u{0}", "\u{1}", "\u{8}", "\u{9}", "\u{A}",
        "\u{C}", "\u{D}", "\u{1F}", "\u{7F}", "é", "e", "\u{301}", "ß", "中", "\u{2028}",
        "\u{FEFF}", "😀", "\u{10FFFF}",
    ]

    static let numbers: [Double] = [
        0, -0.0, 0.1, 0.5, 1.5, -2.25, 1e-7, 1e16, 1e21, 1e300, 5e-324, 9_007_199_254_740_993,
        0x1p53, 0x1p63, -0x1p63, 0x1p64, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        .leastNormalMagnitude,
    ]

    static func value(depth: Int, using rng: inout SeededGenerator) -> JSONValue {
        let pick = Int.random(in: 0..<(depth >= 4 ? 6 : 8), using: &rng)
        switch pick {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &rng))
        case 2: return .int(int(using: &rng))
        case 3: return .double(double(using: &rng))
        case 4, 5: return .string(string(using: &rng))
        case 6:
            let count = Int.random(in: 0..<5, using: &rng)
            return .array((0..<count).map { _ in value(depth: depth + 1, using: &rng) })
        default:
            var members: [String: JSONValue] = [:]
            for _ in 0..<Int.random(in: 0..<5, using: &rng) {
                members[string(using: &rng)] = value(depth: depth + 1, using: &rng)
            }
            return .object(members)
        }
    }

    static func int(using rng: inout SeededGenerator) -> Int64 {
        switch Int.random(in: 0..<4, using: &rng) {
        case 0:
            return [Int64.min, Int64.max, 0, -1, 1 << 53, (1 << 53) + 1].randomElement(
                using: &rng) ?? 0
        case 1: return Int64(bitPattern: rng.next())
        default: return Int64.random(in: -100_000...100_000, using: &rng)
        }
    }

    static func double(using rng: inout SeededGenerator) -> Double {
        if Bool.random(using: &rng) { return numbers.randomElement(using: &rng) ?? 0 }
        while true {
            let candidate = Double(bitPattern: rng.next())
            if candidate.isFinite { return candidate }
        }
    }

    static func string(using rng: inout SeededGenerator) -> String {
        var text = String.UnicodeScalarView()
        for _ in 0..<Int.random(in: 0..<8, using: &rng) {
            text.append(scalars.randomElement(using: &rng) ?? "a")
        }
        return String(text)
    }

    static let alphabet =
        Array(#"{}[]",:\ 0123456789eE.-+atfnu"#.utf8)
        + [0x00, 0x0A, 0x7F, 0x80, 0xC3, 0xED, 0xF0, 0xFF]

    static func mutate(_ bytes: inout [UInt8], using rng: inout SeededGenerator) {
        guard !bytes.isEmpty else {
            bytes.append(alphabet.randomElement(using: &rng) ?? 0x30)
            return
        }
        let at = Int.random(in: 0..<bytes.count, using: &rng)
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: bytes.remove(at: at)
        case 1: bytes.insert(alphabet.randomElement(using: &rng) ?? 0x30, at: at)
        case 2: bytes[at] = alphabet.randomElement(using: &rng) ?? 0x30
        case 3: bytes.removeSubrange(at...)
        default:
            let end = min(bytes.count, at + Int.random(in: 1..<8, using: &rng))
            bytes.insert(contentsOf: bytes[at..<end], at: at)
        }
    }
}
