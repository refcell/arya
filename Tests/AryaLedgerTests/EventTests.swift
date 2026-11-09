import AryaCore
import Foundation
import Testing

@testable import AryaLedger

private func sampleLine() throws -> (event: Event, line: [UInt8]) {
    let draft = EventDraft(
        type: .runDecision, actor: .steward(triage), steward: triage,
        run: RunID(rawValue: "run_01KDVDNA000000000000000001")!,
        payload: ["v": 1, "decision": ["id": "d1", "choice": "bug", "rationale": "a/b é"]])
    return try LedgerLine.seal(
        draft, seq: 42, prev: Event.genesisHash,
        id: EventID(rawValue: "ev_01KDVDNA000000000000000002")!,
        at: Timestamp("2026-01-01T12:00:00.000Z")!)
}

@Test func envelopeLineGolden() throws {
    let (event, line) = try sampleLine()
    #expect(String(decoding: line, as: UTF8.self) == (try fixtureText("event-line.jsonl")))
    #expect(event.hash.count == 64)
    #expect(String(decoding: line, as: UTF8.self).hasSuffix(#","hash":"\#(event.hash)"}"#))
}

@Test func openVerifiesAndDecodes() throws {
    let (event, line) = try sampleLine()
    #expect(try LedgerLine.open(line) == event)
}

@Test func openRejectsTampering() throws {
    var (_, line) = try sampleLine()
    let index = line.firstIndex(of: UInt8(ascii: "b"))!
    line[index] = UInt8(ascii: "B")
    #expect(throws: LineProblem.hashMismatch) { try LedgerLine.open(line) }
    #expect(throws: LineProblem.tooShort) { try LedgerLine.open(Array("{}".utf8)) }
    var noSuffix = try sampleLine().line
    noSuffix.removeLast(3)
    noSuffix += Array("x\"}".utf8)
    #expect(throws: LineProblem.missingHashSuffix) { try LedgerLine.open(noSuffix) }
}

@Test func verifyNeverReencodes() throws {
    // A writer that formats numbers differently still verifies: only bytes are hashed.
    let body =
        #"{"actor":{"id":"arya","kind":"system"},"at":"2026-01-01T00:00:00.000Z","#
        + #""id":"ev_1","payload":{"x":1.50},"prev":"\#(Event.genesisHash)","seq":1,"#
        + #""type":"system.started","v":1}"#
    let hash = LedgerLine.hexSHA256(Array(body.utf8))
    let line = String(body.dropLast()) + #","hash":"\#(hash)"}"#
    let event = try LedgerLine.open(Array(line.utf8))
    #expect(event.payload["x"] == .double(1.5))
    #expect(event.hash == hash)
}

@Test func payloadMustBeAnObject() {
    let draft = EventDraft(type: .systemStarted, actor: .system, payload: [1])
    #expect(throws: LedgerError.payloadNotObject) {
        try LedgerLine.seal(
            draft, seq: 1, prev: Event.genesisHash, id: EventID(rawValue: "ev_1")!,
            at: Timestamp(millis: 0))
    }
}

@Test func actorsAndTypes() throws {
    #expect(try CanonicalJSON.string(Actor.local) == #"{"id":"local","kind":"human"}"#)
    #expect(Actor.steward(triage).description == "steward:st_triage")
    #expect(EventType.runAdapterEvent.namespace == "run")
    #expect(EventType.all.count == 43)
    #expect(Set(EventType.all).count == EventType.all.count)
}
