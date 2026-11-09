import Foundation
import Testing

@testable import AryaCore

@Test func moduleLinks() {
    #expect(AryaCore.name == "AryaCore")
}

@Test func prefixedIDsValidate() {
    #expect(StewardID(rawValue: "st_triage")?.body == "triage")
    #expect(StewardID(rawValue: "triage") == nil)
    #expect(StewardID(rawValue: "st_") == nil)
    #expect(StewardID(rawValue: "st_a b") == nil)
    #expect(RunID(body: "01J")?.rawValue == "run_01J")
    #expect(EventID(rawValue: "run_x") == nil)
    #expect(ApprovalID(rawValue: "ap_1") != nil)
    #expect(CaseID(rawValue: "case-0007") != nil)
    #expect(CaseID(rawValue: "tracker:ISSUE-7.v2") != nil)
    #expect(CaseID(rawValue: "") == nil)
}

@Test func idsCodeAsPlainStrings() throws {
    struct Box: Codable, Equatable {
        var steward: StewardID
        var caseID: CaseID
    }
    let box = Box(steward: StewardID(rawValue: "st_triage")!, caseID: CaseID(rawValue: "c1")!)
    #expect(try CanonicalJSON.string(box) == #"{"caseID":"c1","steward":"st_triage"}"#)
    let back = try JSONDecoder().decode(
        Box.self, from: Data(#"{"caseID":"c1","steward":"st_triage"}"#.utf8))
    #expect(back == box)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(StewardID.self, from: Data(#""run_1""#.utf8))
    }
}

@Test func idsSortByBytes() {
    let ids = ["st_b", "st_B", "st_a"].compactMap(StewardID.init(rawValue:)).sorted()
    #expect(ids.map(\.rawValue) == ["st_B", "st_a", "st_b"])
}

@Test func ulidEncodesKnownValues() {
    #expect(ULID.encode(millis: 0, randomHigh: 0, randomLow: 0) == "00000000000000000000000000")
    #expect(
        ULID.encode(millis: 0xFFFF_FFFF_FFFF, randomHigh: 0xFFFF, randomLow: .max)
            == "7ZZZZZZZZZZZZZZZZZZZZZZZZZ")
    // 2026-01-01T00:00:00.000Z = 1767225600000 ms; time is the first 10 characters.
    let body = ULID.encode(millis: 1_767_225_600_000, randomHigh: 0, randomLow: 1)
    #expect(body == "01KDVDNA00" + "0000000000000001")
}
