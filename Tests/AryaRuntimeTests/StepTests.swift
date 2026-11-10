import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private func stepEvents(_ harness: RunHarness) async throws -> [RuntimeEvent] {
    try await harness.sink.events(from: 1).filter { $0.type.hasPrefix("run.step.") }
}

private func field(_ event: RuntimeEvent, _ name: String) -> JSONValue? {
    event.payload.objectValue?[name]
}

@Test func aToolCallBecomesAStartedOutputAndFinishedStep() async throws {
    let harness = RunHarness(
        FakeScript.Run(
            steps: [
                toolCall,
                .event(RunEvent(.toolResult(id: "t1", output: "open, 3 replies", isError: false))),
            ], result: triageResult))
    _ = try await harness.start()
    let steps = try await stepEvents(harness)
    #expect(steps.map(\.type) == ["run.step.started", "run.step.output", "run.step.finished"])
    #expect(field(steps[0], "tool") == "tracker.get")
    #expect(field(steps[0], "input") == #"{"id":"ISSUE-7"}"#)
    #expect(field(steps[1], "text") == "open, 3 replies")
    #expect(field(steps[1], "seq") == 1)
    #expect(field(steps[2], "ok") == true)
    #expect(field(steps[2], "chunks") == 1)
    #expect(field(steps[2], "bytes") == 15)
    #expect(steps.allSatisfy { $0.draft.actor.kind == "adapter" && $0.draft.run != nil })
}

@Test func streamedToolOutputIsRecordedChunkByChunk() async throws {
    let chunk = { (text: String) in
        FakeScript.Step.event(
            RunEvent(.other(kind: "tool_output", fields: ["id": "t1", "text": .string(text)])))
    }
    let harness = RunHarness(
        FakeScript.Run(
            steps: [
                toolCall, chunk("building…\n"), chunk("tests passed\n"),
                .event(RunEvent(.toolResult(id: "t1", output: "done", isError: true))),
            ], result: triageResult))
    _ = try await harness.start()
    let steps = try await stepEvents(harness)
    let outputs = steps.filter { $0.type == "run.step.output" }
    #expect(outputs.map { field($0, "seq") } == [1, 2])
    #expect(outputs.map { field($0, "text") } == ["building…\n", "tests passed\n"])
    let finished = try #require(steps.last)
    #expect(field(finished, "ok") == false)
    #expect(field(finished, "chunks") == 2)
}

@Test func longOutputGoesToABlobWithAPreview() async throws {
    let long = String(repeating: "x", count: StepText.inlineLimit + 1)
    let harness = RunHarness(
        FakeScript.Run(
            steps: [
                toolCall,
                .event(RunEvent(.toolResult(id: "t1", output: .string(long), isError: false))),
            ], result: triageResult))
    _ = try await harness.start()
    let output = try #require(try await stepEvents(harness).first { $0.type == "run.step.output" })
    let key = try #require(field(output, "blob")?.stringValue)
    #expect(await harness.sink.blob(key) == Data(long.utf8))
    #expect(field(output, "text")?.stringValue?.utf8.count == StepText.previewBytes)
    #expect(field(output, "bytes") == .int(Int64(long.utf8.count)))
}

@Test func chunksNeverSplitACharacter() {
    let pieces = StepText.chunks(String(repeating: "é", count: 5), limit: 3)
    #expect(pieces == ["é", "é", "é", "é", "é"])
    #expect(StepText.chunks("").isEmpty)
    #expect(StepText.preview("short") == ("short", false))
}
