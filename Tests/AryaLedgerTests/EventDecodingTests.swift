import AryaCore
import Foundation
import Testing

@testable import AryaLedger

/// `LedgerLine.open` builds events with `JSONParser` instead of `JSONDecoder`. These tests
/// pin it to what the old decoder path accepted, rejected, and produced.

/// Seals any object text the way the writer does, so `open` gets past the hash check.
private func sealed(_ body: String) -> [UInt8] {
    var line = Array(body.utf8)
    let hash = LedgerLine.hexSHA256(line)
    line.removeLast()
    return line + Array(#","hash":"\#(hash)"}"#.utf8)
}

/// The previous `open`: `JSONDecoder` plus the same envelope checks.
private func decoderOpen(_ line: [UInt8]) -> Event? {
    guard let event = try? JSONDecoder().decode(Event.self, from: Data(line)), event.v == 1,
        case .object = event.payload, event.prev.utf8.count == 64,
        event.prev.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    return event
}

private let prev = String(repeating: "0", count: 64)

private func envelope(replacing field: String? = nil, with value: String? = nil) -> String {
    var fields: [(String, String)] = [
        ("actor", #"{"id":"local","kind":"human"}"#), ("at", #""2026-01-01T12:00:00.000Z""#),
        ("id", #""ev_01KDVDNA000000000000000002""#), ("payload", #"{"v":1}"#),
        ("prev", "\"\(prev)\""), ("run", #""run_01KDVDNA000000000000000001""#), ("seq", "7"),
        ("steward", #""st_triage""#), ("type", #""run.decision""#), ("v", "1"),
    ]
    if let field {
        fields.removeAll { $0.0 == field }
        if let value { fields.append((field, value)) }
    }
    return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
}

@Test func openMatchesTheDecoderOnEnvelopeEdgeCases() {
    let variants: [(String?, String?)] = [
        (nil, nil), ("steward", nil), ("steward", "null"), ("steward", #""triage""#),
        ("steward", "1"), ("run", nil), ("run", "null"), ("run", #""st_x""#),
        ("actor", #"{"id":"local","kind":"human","extra":true}"#),
        ("actor", #"{"id":"local","kind":"robot"}"#), ("actor", #"{"kind":"human"}"#),
        ("actor", "null"), ("v", #""1""#), ("v", "1.0"), ("v", "2"), ("v", nil), ("seq", "1e0"),
        ("seq", "1.5"), ("seq", "-3"), ("seq", "9223372036854775808"), ("seq", nil),
        ("at", #""yesterday""#), ("at", #""2026-01-01T12:00:00Z""#), ("id", #""run_1""#),
        ("id", "null"), ("payload", "[1]"), ("payload", "null"), ("payload", nil),
        ("payload", #"{"n":1e+16,"s":"\u00e9\ud83d\ude00","a":[1,],"o":{}}"#),
        ("prev", #""abc""#), ("prev", "\"\(String(repeating: "A", count: 64))\""),
        ("type", "3"), ("type", #""""#), ("extra", #"{"deep":[1,2,3]}"#),
    ]
    for (field, value) in variants {
        let line = sealed(envelope(replacing: field, with: value))
        let expected = decoderOpen(line)
        let actual = try? LedgerLine.open(line)
        #expect(actual == expected, "\(field ?? "-") = \(value ?? "missing")")
    }
}

@Test func openMatchesTheDecoderOnSpacingAndDuplicateKeys() {
    let bodies = [
        #"{ "seq" : 7 , "v":1,"#
            + String(envelope(replacing: "seq").dropFirst()),
        #"{"seq":7,"seq":8,"# + String(envelope(replacing: "seq").dropFirst()),
    ]
    for body in bodies {
        let line = sealed(body)
        #expect(decoderOpen(line) != nil)
        #expect((try? LedgerLine.open(line)) == decoderOpen(line))
    }
}

@Test func openMatchesTheDecoderOnAWrittenLedger() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    var rng = SeededGenerator(7)
    let texts = ["plain", "quote \" slash / back \\", "tab\tnew\nline", "é 中 😀", "\u{1}"]
    let drafts = (0..<200).map { index -> EventDraft in
        let payload: JSONValue = [
            "v": 1, "i": .int(Int64(index)), "r": .double(Double(rng.next() % 10_000) / 7),
            "t": .string(texts[index % texts.count]), "big": .double(1e16), "list": [true, nil],
        ]
        return EventDraft(
            type: index % 2 == 0 ? .runDecision : EventType("custom.thing"),
            actor: index % 3 == 0 ? .system : .steward(triage), steward: triage, payload: payload)
    }
    try store.append(drafts)
    for line in try home.lines(1) {
        let bytes = Array(line.utf8)
        let expected = try #require(decoderOpen(bytes))
        #expect(try LedgerLine.open(bytes) == expected)
    }
}

@Test func sealRefusesPayloadsTooDeepToReadBack() throws {
    var deep: JSONValue = 1
    // Envelope and payload objects take two levels; `deep` fills the rest.
    for _ in 0..<(JSONParser.maxDepth - 2) { deep = .array([deep]) }
    let fits = EventDraft(type: .runDecision, actor: .local, payload: ["x": deep])
    let id = EventID(rawValue: "ev_01KDVDNA000000000000000002")!
    let at = Timestamp(millis: 0)
    let line = try LedgerLine.seal(fits, seq: 1, prev: prev, id: id, at: at).line
    #expect(try LedgerLine.open(line).payload == ["x": deep])
    let tooDeep = EventDraft(type: .runDecision, actor: .local, payload: ["x": .array([deep])])
    #expect(throws: LedgerError.payloadTooDeep) {
        try LedgerLine.seal(tooDeep, seq: 1, prev: prev, id: id, at: at)
    }
}
