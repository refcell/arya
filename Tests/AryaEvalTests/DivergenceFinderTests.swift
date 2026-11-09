import Testing

@testable import AryaEval

private func event(_ seq: Int, _ type: String, _ payload: [String: EvalValue]) -> ReplayEvent {
    ReplayEvent(seq: seq, type: type, payload: .object(payload))
}

@Test func identicalRunsHaveNoDivergence() {
    let events = [event(1, "run.decision", ["choice": .string("bug")])]
    let shifted = [event(9, "run.decision", ["choice": .string("bug")])]
    #expect(DivergenceFinder.firstDivergence(recorded: events, replayed: shifted) == nil)
}

@Test func reportsFirstDifferingFieldWithBothVersions() {
    let recorded = [
        event(1, "run.decision", ["choice": .string("bug")]),
        event(2, "action.proposed", ["kind": .string("label"), "target": .string("ISSUE-7")]),
    ]
    let replayed = [
        event(1, "run.decision", ["choice": .string("bug")]),
        event(2, "action.proposed", ["kind": .string("label"), "target": .string("ISSUE-8")]),
    ]
    let found = DivergenceFinder.firstDivergence(recorded: recorded, replayed: replayed)
    #expect(found?.index == 1)
    #expect(found?.path == "payload.target")
    #expect(found?.recorded == recorded[1])
    #expect(found?.replayed == replayed[1])
}

@Test func reportsTypeMismatchAndMissingEvents() {
    let a = [event(1, "run.decision", [:])]
    let b = [event(1, "run.finished", [:])]
    #expect(DivergenceFinder.firstDivergence(recorded: a, replayed: b)?.path == "type")
    let extra = DivergenceFinder.firstDivergence(recorded: a, replayed: a + b)
    #expect(extra?.path == "event")
    #expect(extra?.recorded == nil)
    #expect(extra?.replayed == b[0])
}

@Test func pathsCoverArraysAndMissingKeys() {
    let a: EvalValue = .object(["xs": .array([.number(1), .number(2)])])
    let b: EvalValue = .object(["xs": .array([.number(1), .number(3)])])
    let c: EvalValue = .object(["xs": .array([.number(1)])])
    let d: EvalValue = .object(["xs": .array([.number(1), .number(2)]), "y": .null])
    #expect(DivergenceFinder.firstDifference(a, b, path: "p") == "p.xs[1]")
    #expect(DivergenceFinder.firstDifference(a, c, path: "p") == "p.xs[1]")
    #expect(DivergenceFinder.firstDifference(a, d, path: "p") == "p.y")
}
