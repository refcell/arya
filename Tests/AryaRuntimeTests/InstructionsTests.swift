import Testing

@testable import AryaRuntime

private let triageInputs = InstructionInputs(
    name: "Issue triage",
    outcome: "Every new issue in the tracker is labeled and routed within one hour.",
    metric: InstructionMetric(
        name: "triaged_within_1h", unit: "ratio", direction: "up", target: 0.95),
    guardrails: ["Never close an issue.", "Ask before assigning\nto a person."],
    bindings: [
        InstructionBinding(
            id: "tracker", kind: "mcp", read: ["search", "get"],
            actions: ["label", "comment", "assign"]),
        InstructionBinding(id: "person:alex", kind: "person"),
    ],
    memory: [InstructionNote(id: "mem_000002", text: "Login issues are usually auth bugs.")],
    routines: [
        InstructionRoutine(
            name: "weekly-digest", version: "9f2c4b1e77aa0011", summary: "Post the digest."),
        InstructionRoutine(name: "dedupe", version: "51ab00ccddee9988", summary: "Find dupes."),
    ]
)

private let golden = """
    You are Issue triage, a steward in arya. You own this outcome:
    Every new issue in the tracker is labeled and routed within one hour.

    ## Success metric
    - triaged_within_1h (ratio, higher is better), target 0.95

    ## Guardrails
    - Never close an issue.
    - Ask before assigning to a person.

    ## Bindings
    - tracker (mcp); read: search, get; propose: label, comment, assign
    - person:alex (person)

    ## Memory
    - [mem_000002] Login issues are usually auth bugs.

    ## Routines
    - dedupe @51ab00ccddee: Find dupes.
    - weekly-digest @9f2c4b1e77aa: Post the digest.

    ## How to finish
    Do not change any external system yourself. Read through the tools you were given, then \
    return one result matching the result schema: a summary, your decisions, and the actions \
    you propose. arya applies the approval policy and carries out approved actions. To run a \
    routine, propose an action of kind routine with params.name.

    """

@Test func composesGoldenInstructions() {
    #expect(InstructionComposer.compose(triageInputs) == golden)
}

@Test func compositionIsDeterministic() {
    var shuffled = triageInputs
    shuffled.routines.reverse()
    #expect(InstructionComposer.compose(shuffled) == InstructionComposer.compose(triageInputs))
}

@Test func omitsEmptySections() {
    let text = InstructionComposer.compose(
        InstructionInputs(name: "Minimal", outcome: "Keep the inbox at zero."))
    #expect(!text.contains("## Guardrails"))
    #expect(!text.contains("## Memory"))
    #expect(!text.contains("## Success metric"))
    #expect(text.hasPrefix("You are Minimal, a steward in arya."))
    #expect(text.contains("## How to finish"))
}

@Test func integerTargetsPrintWithoutFraction() {
    let inputs = InstructionInputs(
        name: "Inbox", outcome: "Answer every message.",
        metric: InstructionMetric(name: "open", unit: "count", direction: "down", target: 0))
    #expect(
        InstructionComposer.compose(inputs).contains("- open (count, lower is better), target 0"))
}
