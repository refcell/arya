import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private let script = "printf 'tagged %s' \"$1\"; echo done > marker\n"
private let failing = "echo nope >&2; exit 3\n"

private func routineRun(_ body: String? = nil, args: [String] = ["MSG-9"]) -> FakeScript.Run {
    var result: JSONValue = [
        "summary": "Tagged the message.",
        "decisions": [["id": "d1", "choice": "billing"]],
        "actions": [
            [
                "id": "a1", "kind": "routine",
                "params": ["name": "tag-billing", "args": .array(args.map(JSONValue.string))],
            ]
        ],
    ]
    if let body {
        result[set: "routines"] = [
            ["name": "tag-billing", "language": "sh", "content": .string(body), "reason": "reuse"]
        ]
    }
    return FakeScript.Run(input: "New message MSG-9", result: result)
}

/// A steward whose charter auto-runs `rule` routines (for example `routine:tag-billing@<v>`).
private func open(_ runs: [FakeScript.Run], rules: [String] = []) async throws -> Opened {
    let opened = try await Opened(runs)
    var charter = inboxCharter()
    charter.policy = Policy(rules: rules.map { Policy.Rule(action: $0, decision: .auto) })
    _ = try await opened.workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    return opened
}

private func promote(_ opened: Opened, _ body: String) async throws -> String {
    let source = try RoutineSource(name: "tag-billing", language: .sh, content: body)
    let steward = StewardID(unchecked: "st_inbox")
    for draft in [
        try EventDraft(
            try source.propose(into: BlobStore(home: opened.home.url)), actor: .system,
            steward: steward),
        try EventDraft(
            RoutinePromotedPayload(name: "tag-billing", version: source.version), actor: .system,
            steward: steward),
    ] {
        _ = try await opened.workspace.sink.append(RuntimeEventDraft(draft))
    }
    return source.version
}

private func entry(_ opened: Opened, _ type: String) async throws -> LedgerEntry? {
    try await opened.workspace.ledger().last { $0.type == type }
}

@Test func routinesARunProposesArePendingUntilGated() async throws {
    let opened = try await open([routineRun(script)])

    let run = try await opened.workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let routines = try await opened.workspace.routines(steward: "st_inbox")
    #expect(routines.map(\.name) == ["tag-billing"])
    #expect(routines.first?.liveVersion == nil)
    let version = try #require(routines.first?.latestVersion)
    let detail = try await opened.workspace.routine(
        steward: "st_inbox", name: "tag-billing", version: version)
    #expect(detail?.run == run.id)
    #expect(detail?.gate == .pending)
    #expect(detail?.content == script)
    #expect(try await entry(opened, "routine.proposed")?.actorKind == "steward")
    // The routine is not live, so its action is denied, never run.
    #expect(try await entry(opened, "action.executed") == nil)
}

@Test func aPinnedRoutineRunsInTheRunScratchDirectory() async throws {
    let source = try RoutineSource(name: "tag-billing", language: .sh, content: script)
    let opened = try await open([routineRun()], rules: ["routine:tag-billing@\(source.version)"])
    _ = try await promote(opened, script)

    let run = try await opened.workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let executed = try #require(try await entry(opened, "action.executed"))
    #expect(executed.payload.contains("tagged MSG-9"))
    let marker = HomeLayout.work(opened.home.url, run: RunID(unchecked: run.id))
        .appendingPathComponent("marker")
    #expect(try String(contentsOf: marker, encoding: .utf8) == "done\n")
}

@Test func anUnpinnedRoutineWaitsForApprovalThenRuns() async throws {
    let opened = try await open([routineRun()])
    _ = try await promote(opened, script)

    _ = try await opened.workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    #expect(try await entry(opened, "action.executed") == nil)
    let approval = try #require(try await opened.workspace.approvals().first)

    _ = try await opened.workspace.approve(approval.id)

    #expect(try await entry(opened, "action.executed")?.payload.contains("tagged MSG-9") == true)
}

@Test func aFailingRoutineRecordsActionFailedWithItsOutput() async throws {
    let source = try RoutineSource(name: "tag-billing", language: .sh, content: failing)
    let opened = try await open([routineRun()], rules: ["routine:tag-billing@\(source.version)"])
    _ = try await promote(opened, failing)

    _ = try await opened.workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let failed = try #require(try await entry(opened, "action.failed"))
    #expect(failed.payload.contains("exited with 3"))
    #expect(failed.payload.contains("nope"))
}
