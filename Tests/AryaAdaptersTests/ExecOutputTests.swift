import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

@Test func lastJSONBlockWins() {
    let text = """
        Thinking out loud.
        ```json
        {"summary": "first"}
        ```
        Some more text.
          ```JSON
          {"summary": "second", "decisions": [{"id": "d1", "choice": "bug"}]}
          ```
        ```sh
        echo not json
        ```
        """
    #expect(ExecOutput.lastJSONBlock(in: text)?["summary"] == "second")
}

@Test(arguments: [
    "no fence at all", "```json\n{\"a\":1}\n", "```json\nnot json\n```", "```\n{\"a\":1}\n```",
])
func noUsableJSONBlock(_ text: String) {
    #expect(ExecOutput.lastJSONBlock(in: text) == nil)
}

@Test func jsonLinesAreClassified() {
    #expect(
        ExecOutput.parse(jsonLine: #"{"result":{"summary":"ok"}}"#) == .result(["summary": "ok"]))
    #expect(
        ExecOutput.parse(jsonLine: #"{"kind":"thinking","text":"hm"}"#)
            == .event(RunEvent(.thinking(text: "hm"))))
    #expect(
        ExecOutput.parse(jsonLine: #"{"cost":{"costMicros":5}}"#)
            == .cost(CostResult(costMicros: 5)))
    #expect(ExecOutput.parse(jsonLine: "plain text") == .other("plain text"))
    #expect(ExecOutput.parse(jsonLine: "[1,2]") == .other("[1,2]"))
    #expect(ExecOutput.parse(jsonLine: #"{"kind":"message"}"#) == .other(#"{"kind":"message"}"#))
}

let resultSchema: JSONValue = [
    "type": "object", "required": ["summary"],
    "properties": [
        "summary": ["type": "string"],
        "decisions": [
            "type": "array", "maxItems": 2,
            "items": [
                "type": "object", "required": ["id", "choice"], "additionalProperties": false,
                "properties": [
                    "id": ["type": "string"], "choice": ["enum": ["bug", "question"]],
                ],
            ],
        ],
        "score": ["type": ["integer", "null"]],
    ],
]

@Test(
    arguments: [
        (["summary": "ok"] as JSONValue, nil),
        (["summary": "ok", "decisions": [["id": "d1", "choice": "bug"]], "score": 3], nil),
        (["summary": "ok", "score": nil], nil),
        (["summary": "ok", "score": 2.0], nil),
        ([:], "$: missing required summary"),
        (["summary": 1], "$.summary: expected string"),
        (["summary": "ok", "score": 2.5], "$.score: expected integer or null"),
        (
            ["summary": "ok", "decisions": [["id": "d1", "choice": "won't fix"]]],
            "$.decisions[0].choice: not one of the allowed values"
        ),
        (
            ["summary": "ok", "decisions": [["id": "d1", "choice": "bug", "x": 1]]],
            "$.decisions[0]: unexpected property x"
        ),
        (["summary": "ok", "decisions": [[:], [:], [:]]], "$.decisions: more than 2 items"),
        ("text", "$: expected object"),
    ] as [(JSONValue, String?)])
func resultSchemaChecks(_ value: JSONValue, _ problem: String?) {
    #expect(ResultSchema.violation(of: resultSchema, by: value) == problem)
}

@Test func streamJSONLinesAreMapped() {
    #expect(ExecOutput.parse(streamJSONLine: #"{"type":"system","subtype":"init"}"#) == .other)
    #expect(ExecOutput.parse(streamJSONLine: "not json") == .other)
    let assistant = #"""
        {"type":"assistant","message":{"role":"assistant","content":[
        {"type":"thinking","thinking":"hm"},{"type":"text","text":"Looking."},
        {"type":"tool_use","id":"t1","name":"tracker_get","input":{"id":"ISSUE-1"}}]}}
        """#.replacingOccurrences(of: "\n", with: "")
    #expect(
        ExecOutput.parse(streamJSONLine: assistant)
            == .events([
                RunEvent(.thinking(text: "hm")),
                RunEvent(.message(role: "assistant", text: "Looking.")),
                RunEvent(.toolCall(id: "t1", tool: "tracker_get", input: ["id": "ISSUE-1"])),
            ]))
    let user = #"""
        {"type":"user","message":{"role":"user","content":[
        {"type":"tool_result","tool_use_id":"t1","content":"open","is_error":false}]}}
        """#.replacingOccurrences(of: "\n", with: "")
    #expect(
        ExecOutput.parse(streamJSONLine: user)
            == .events([RunEvent(.toolResult(id: "t1", output: "open", isError: false))]))
    let result = #"""
        {"type":"result","subtype":"success","is_error":false,"result":"Done.",
        "total_cost_usd":0.0123,"usage":{"input_tokens":100,"output_tokens":20,
        "cache_read_input_tokens":800,"cache_creation_input_tokens":50}}
        """#.replacingOccurrences(of: "\n", with: "")
    #expect(
        ExecOutput.parse(streamJSONLine: result)
            == .final(
                text: "Done.", isError: false,
                cost: CostResult(inputTokens: 950, outputTokens: 20, costMicros: 12300)))
    #expect(
        ExecOutput.parse(streamJSONLine: #"{"type":"result","subtype":"error_max_turns"}"#)
            == .final(text: "", isError: true, cost: CostResult()))
}

@Test func codexJSONLinesAreMapped() {
    #expect(ExecOutput.parse(codexJSONLine: #"{"type":"turn.started"}"#) == .other)
    #expect(
        ExecOutput.parse(codexJSONLine: #"{"type":"item.started","item":{"type":"reasoning"}}"#)
            == .other)
    let failedCommand = #"""
        {"type":"item.completed","item":{"id":"c1","type":"command_execution",
        "command":"false","status":"failed","exit_code":1,"aggregated_output":""}}
        """#.replacingOccurrences(of: "\n", with: "")
    #expect(
        ExecOutput.parse(codexJSONLine: failedCommand)
            == .events(
                [
                    RunEvent(.toolCall(id: "c1", tool: "shell", input: ["command": "false"])),
                    RunEvent(.toolResult(id: "c1", output: "", isError: true)),
                ], reply: nil))
    #expect(
        ExecOutput.parse(codexJSONLine: #"{"type":"turn.failed","error":{"message":"boom"}}"#)
            == .failed("boom"))
    #expect(
        ExecOutput.parse(
            codexJSONLine:
                #"{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":1}}"#)
            == .usage(CostResult(inputTokens: 3, outputTokens: 1)))
}
