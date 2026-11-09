import AryaCore
import Foundation
import Testing

@testable import AryaLedger

/// One sample of a payload type, type-erased for the golden table.
struct PayloadSample: Sendable, CustomStringConvertible {
    let type: EventType
    let encode: @Sendable () throws -> JSONValue
    let roundTrips: @Sendable (Data) throws -> Bool

    init<P: EventPayload>(_ value: P) {
        type = P.type
        encode = { try CanonicalJSON.jsonValue(value) }
        roundTrips = { try JSONDecoder().decode(P.self, from: $0) == value }
    }

    var description: String { type.rawValue }
}

private let run1 = RunID(rawValue: "run_01KDVDNA000000000000000001")!
private let ap1 = ApprovalID(rawValue: "ap_01KDVDNA000000000000000003")!
private let reh1 = RehearsalID(rawValue: "reh_01KDVDNA000000000000000005")!
private let label = ProposedAction(
    id: "a1", kind: "label", binding: "tracker", target: "tracker:ISSUE-7",
    params: ["label": "bug"], rationale: "Stack trace points at the login handler.")

let payloadSamples: [PayloadSample] = [
    PayloadSample(
        RunStarted(
            input: RunInputRecord(kind: .case, text: "New issue: login page times out"),
            charterVersion: 1, routines: ["summarize": String(repeating: "ab", count: 32)],
            memory: ["v": 1, "notes": ["mem_1"]], adapter: "fake", effort: .medium,
            instructions: "Outcome: every new issue is labeled.", limits: Limits(),
            rehearsal: reh1, caseID: CaseID(rawValue: "case-0007")!, sample: 1)),
    PayloadSample(RunInputReceived(kind: .message, text: "It is a bug.")),
    PayloadSample(
        RunAdapterEvent(
            direction: .received,
            message: ["jsonrpc": "2.0", "method": "run/event", "params": ["seq": 1]])),
    PayloadSample(
        RunToolCall(id: "t1", binding: "tracker", tool: "get", input: ["id": "ISSUE-7"])),
    PayloadSample(RunToolResult(id: "t1", output: ["title": "Login"], source: .recorded)),
    PayloadSample(
        RunDecision(decision: RecordedDecision(id: "d1", choice: "bug", rationale: "Crash."))),
    PayloadSample(
        RunFinished(
            status: .completed, summary: "Labeled ISSUE-7 as a bug.",
            cost: RunCost(inputTokens: 1200, outputTokens: 300, costMicros: 4500),
            counts: RunCounts(decisions: 1, actions: 1))),
    PayloadSample(RunFailed(reason: "interrupted", detail: "adapter process gone")),
    PayloadSample(ActionProposed(action: label, disposition: .ask, reason: "default")),
    PayloadSample(ActionExecuted(action: "a1", approval: ap1, output: ["ok": true])),
    PayloadSample(ActionFailed(action: "a1", error: "tracker returned 503")),
    PayloadSample(ActionRejected(action: "a2", reason: "rule:close")),
    PayloadSample(
        ApprovalRequested(
            approval: ap1, action: label, expiresAt: Timestamp(millis: 1_767_312_000_000))),
    PayloadSample(ApprovalGranted(approval: ap1, note: "Go ahead.")),
    PayloadSample(ApprovalDenied(approval: ap1, note: "Not this one.")),
    PayloadSample(ApprovalExpired(approval: ap1)),
    PayloadSample(EnvRead(readings: [.time(Timestamp(millis: 0)), .random(42)])),
    PayloadSample(
        SystemRepair(
            segment: "000001.jsonl", offset: 4096, length: 17,
            blob: String(repeating: "ef", count: 32), reason: "no trailing newline")),
    PayloadSample(SystemStarted(process: "test", version: "0.1.0")),
    PayloadSample(
        SystemKeyAdded(
            key: "key_0123456789abcdef", publicKey: String(repeating: "A", count: 43) + "=",
            replaces: "key_fedcba9876543210", signature: String(repeating: "B", count: 86) + "==")),
    PayloadSample(
        SystemCheckpoint(
            through: 12, head: String(repeating: "ab", count: 32),
            segments: [
                CheckpointSegment(
                    name: "000001.jsonl", sha256: String(repeating: "cd", count: 32), first: 1,
                    last: 9)
            ], projections: ["runs.v1": String(repeating: "ef", count: 32)],
            keys: ["key_0123456789abcdef": String(repeating: "A", count: 43) + "="],
            key: "key_0123456789abcdef", signature: String(repeating: "B", count: 86) + "==")),
]

private func goldenName(_ type: EventType) -> String { "payloads/\(type.rawValue).json" }

@Test(arguments: payloadSamples)
func payloadGolden(_ sample: PayloadSample) throws {
    let text = try CanonicalJSON.string(sample.encode())
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = dir.appendingPathComponent("Fixtures").appendingPathComponent(goldenName(sample.type))
    if ProcessInfo.processInfo.environment["ARYA_UPDATE_GOLDENS"] == "1" {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text + "\n").utf8).write(to: url)
    }
    #expect(text == (try fixtureText(goldenName(sample.type))))
    #expect(try sample.roundTrips(Data(text.utf8)))
}

@Test func everyLedgerOwnedTypeHasAPayload() {
    // run.*, action.*, approval.*, env.read, and system.* are ledger-owned (decision 0024);
    // the rest live with their writer (0019, 0022, 0023).
    let owned = EventType.all.filter {
        ["run", "action", "approval", "system"].contains($0.namespace) || $0 == .envRead
    }
    #expect(Set(payloadSamples.map(\.type)) == Set(owned))
    #expect(payloadSamples.count == owned.count)
}

@Test func typedPayloadAccess() throws {
    let draft = try EventDraft(SystemStarted(process: "test", version: "0.1.0"), actor: .system)
    let (event, _) = try LedgerLine.seal(
        draft, seq: 1, prev: Event.genesisHash, id: EventID(rawValue: "ev_1")!,
        at: Timestamp(millis: 0))
    #expect(try event.payload(as: SystemStarted.self).process == "test")
    #expect(throws: LedgerError.self) { try event.payload(as: EnvRead.self) }
}

@Test func decodesTheRuntimeApprovalShape() throws {
    // Exactly what the runtime's approval queue writes today.
    let text =
        #"{"action":{"id":"a1","kind":"label","target":"tracker:ISSUE-7"},"#
        + #""approval":"ap_1","kind":"action","to":"local"}"#
    let decoded = try JSONDecoder().decode(ApprovalRequested.self, from: Data(text.utf8))
    #expect(decoded.kind == .action)
    #expect(decoded.action?.kind == "label")
    #expect(decoded.action?.params == nil)
    #expect(try CanonicalJSON.string(decoded) == text)
    let question = #"{"approval":"ap_2","kind":"question","question":"Which label?","to":"local"}"#
    let asked = try JSONDecoder().decode(ApprovalRequested.self, from: Data(question.utf8))
    #expect(asked.question == "Which label?")
    #expect(try CanonicalJSON.string(asked) == question)
}

@Test func decodesTheRuntimeActionShapes() throws {
    let proposed =
        #"{"action":{"id":"a1","kind":"label"},"disposition":"auto","reason":"rule:label"}"#
    let value = try JSONDecoder().decode(ActionProposed.self, from: Data(proposed.utf8))
    #expect(value.disposition == .auto)
    #expect(try CanonicalJSON.string(value) == proposed)
    let rejected = #"{"action":"a2","approval":"ap_1","reason":"denied"}"#
    let refused = try JSONDecoder().decode(ActionRejected.self, from: Data(rejected.utf8))
    #expect(try CanonicalJSON.string(refused) == rejected)
}
