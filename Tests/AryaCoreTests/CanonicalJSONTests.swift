import Foundation
import Testing

@testable import AryaCore

@Test func canonicalGolden() throws {
    let input = try JSONDecoder().decode(JSONValue.self, from: fixture("canonical-input.json"))
    let expected = try fixtureText("canonical-output.json")
    #expect(String(decoding: try CanonicalJSON.bytes(input), as: UTF8.self) == expected)
}

@Test func canonicalIsIdempotent() throws {
    let input = try JSONDecoder().decode(JSONValue.self, from: fixture("canonical-input.json"))
    let once = try CanonicalJSON.encode(input)
    let twice = try CanonicalJSON.encode(try JSONDecoder().decode(JSONValue.self, from: once))
    #expect(once == twice)
}

@Test func keysSortByUTF8Bytes() throws {
    // "Z" (0x5A) < "a" (0x61) < "é" (0xC3 0xA9) < "😀" (0xF0 …). Unicode-aware sorts differ.
    let value: JSONValue = ["é": 1, "a": 2, "Z": 3, "😀": 4, "ab": 5]
    #expect(try CanonicalJSON.string(value) == #"{"Z":3,"a":2,"ab":5,"é":1,"😀":4}"#)
}

@Test func escapes() throws {
    let value: JSONValue = .string("a/b \"q\" \\ \n\t\u{01} ü")
    #expect(try CanonicalJSON.string(value) == #""a/b \"q\" \\ \n\t\u0001 ü""#)
}

@Test func numbers() throws {
    let value: JSONValue = [1, -0.5, 0.95, 1e-7, 3.0, .int(Int64.max), 1e300]
    #expect(
        try CanonicalJSON.string(value)
            == "[1,-0.5,0.95,1e-07,3,9223372036854775807,1e+300]")
    #expect(throws: CanonicalJSONError.nonFiniteNumber) {
        try CanonicalJSON.bytes(JSONValue.double(.nan))
    }
}

@Test func decodingKeepsKinds() throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[1,true,1.5,null,"x"]"#.utf8))
    #expect(value == [.int(1), .bool(true), .double(1.5), .null, "x"])
}

@Test func encodablesGoThroughSortedForm() throws {
    struct Sample: Codable {
        var zeta = 1
        var alpha = "a/b"
        var nested = ["y": [2, 1], "x": [3]]
        var missing: String? = nil
    }
    #expect(
        try CanonicalJSON.string(Sample())
            == #"{"alpha":"a/b","nested":{"x":[3],"y":[2,1]},"zeta":1}"#)
}
