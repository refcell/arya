import AryaCore
import Foundation
import Testing

@testable import AryaLedger

private let day: Int64 = 86_400_000
private let start = Timestamp(millis: 1_767_225_600_000)
private let triageID = StewardID(unchecked: "st_triage")
private let billingID = StewardID(unchecked: "st_billing")

private func stewardNote(_ steward: StewardID?, _ text: String) -> EventDraft {
    EventDraft(type: "test.note", actor: .local, steward: steward, payload: ["text": .string(text)])
}

private func retention(_ steward: StewardID?, _ days: Int?) throws -> EventDraft {
    try EventDraft(SystemRetentionSet(steward: steward, days: days), actor: .local)
}

@Test func retentionSettingsFoldLatestWins() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let store = try LedgerStore(home: home.url, ambient: .fixed())
    try store.append(try retention(nil, 30))
    try store.append(try retention(triageID, 7))
    try store.append(try retention(triageID, 90))
    try store.append(try retention(billingID, 5))
    try store.append(try retention(billingID, nil))
    let policy = try RetentionPolicy.read(LedgerReader(home: home.url))
    #expect(policy.defaultDays == 30)
    #expect(policy.days(for: triageID) == 90)
    #expect(policy.days(for: billingID) == 30)
    #expect(policy.days(for: nil) == 30)
}

@Test func retentionPlansWholeOldSegmentsAndStopsAtTheFirstKeptEvent() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    // One event a day, small segments: about two events per segment.
    let store = try LedgerStore(
        home: home.url, ambient: .fixed(start: start, stepMillis: day / 2),
        segmentLimitBytes: 400)
    for index in 0..<20 { try store.append(stewardNote(triageID, "note \(index)")) }
    try store.append(stewardNote(billingID, "kept"))
    for index in 20..<24 { try store.append(stewardNote(triageID, "note \(index)")) }
    let reader = LedgerReader(home: home.url)
    let now = Timestamp(millis: start.millis + 30 * day)
    var policy = RetentionPolicy()
    #expect(try RetentionPlan.compute(reader, policy: policy, now: now).segments.isEmpty)

    policy.stewards[triageID] = 1
    let plan = try RetentionPlan.compute(reader, policy: policy, now: now)
    #expect(!plan.segments.isEmpty)
    #expect(plan.through < 21)
    #expect(plan.events.keys.sorted() == ["st_triage"])
    #expect(plan.events["st_triage"] == Int(plan.through))
    #expect(plan.bytes > 0)

    policy.defaultDays = 1
    let wider = try RetentionPlan.compute(reader, policy: policy, now: now)
    #expect(wider.through > plan.through)
    #expect(wider.events["st_billing"] == 1)
}
