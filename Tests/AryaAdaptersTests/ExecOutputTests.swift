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
