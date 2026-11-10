import AryaAdapters
import AryaCore
import Foundation

/// One generated run: when it starts and its input (the script's key).
struct PlannedRun {
    let at: Int64
    let input: String
}

/// A generated steward's charter, script, and runs, all from its spec and a seed.
struct GeneratedSteward {
    let spec: StewardSpec
    let charter: Data
    let script: FakeScript
    let runs: [PlannedRun]
    /// Inputs whose run holds an action for a person.
    let held: Set<String>
    /// The adapter name the charter uses and the script is served under.
    var adapter: String { "demo-\(spec.id.dropFirst(3))" }

    /// Builds it. `today` is 00:00 UTC of the day the demo is seeded, in milliseconds.
    init(_ spec: StewardSpec, templates: URL, today: Int64, rng: inout SeededGenerator)
        throws
    {
        self.spec = spec
        let adapter = "demo-\(spec.id.dropFirst(3))"
        charter = try Self.charter(spec, templates: templates, adapter: adapter)
        let fields = try JSONSerialization.jsonObject(with: charter) as? [String: Any] ?? [:]
        var runs: [PlannedRun] = []
        var held: Set<String> = []
        var responses: [String: Any] = [:]
        let total = Double(spec.days)
        var number = 1000
        for day in stride(from: spec.days, through: 0, by: -1) {
            let dayStart = today - Int64(day) * 86_400_000
            // Weekday peaks, quiet weekends (1970-01-01 was a Thursday).
            let weekday = Int((dayStart / 86_400_000 + 3) % 7)  // 0 = Monday
            let busy = Int.random(in: spec.runsPerDay, using: &rng)
            let count = weekday >= 5 ? max(1, busy / 3) : busy + (weekday == 0 ? 1 : 0)
            // One bad week three weeks ago: metrics dip and runs fail more often.
            let badWeek = (15...21).contains(day)
            for slot in 0..<count {
                number += 1
                let detail = spec.details[(number + slot) % spec.details.count]
                let input = "\(spec.prefix)-\(number): \(detail)"
                let hour = 8 + (slot * 10 / max(count, 1)) + Int.random(in: 0...1, using: &rng)
                let minute = Int.random(in: 0...59, using: &rng)
                let at = dayStart + Int64(hour * 3600 + minute * 60) * 1000
                let f = (total - Double(day)) / total
                let noise = Double(Int.random(in: -40...40, using: &rng)) / 1000
                let dip = badWeek ? 0.14 : 0
                let value = min(1, max(0, spec.curve.value(at: f) + noise - dip))
                let holds = spec.askKind != nil && number % spec.askEvery == 0
                let fails = Int.random(in: 0..<(badWeek ? 6 : 25), using: &rng) == 0
                if fails {
                    responses[input] = Self.failure(spec, number: number)
                } else {
                    if holds { held.insert(input) }
                    // The live steward re-planned three days ago, so its PLAN reads recent.
                    responses[input] = Self.response(
                        spec, charter: fields, number: number, detail: detail, value: value,
                        held: holds, replanned: spec.live && day <= 3, rng: &rng)
                }
                runs.append(PlannedRun(at: at, input: input))
            }
        }
        if spec.live {
            responses[Self.liveInput(spec)] = Self.live(spec)
        }
        for message in spec.messages where message.intent != "correct" {
            let verb = message.intent == "handoff" ? "hands this to you" : "asks"
            responses["\(message.person) \(verb): \(message.text)"] = Self.reply(spec, message.text)
        }
        let document: [String: Any] = [
            "v": 1, "responses": responses,
            "default": [
                "events": [
                    ["kind": "status", "state": "working", "detail": "checking for new work"]
                ],
                "status": "completed",
                "result": ["summary": "Checked for new work; nothing new since the last run."],
            ],
        ]
        script = try JSONDecoder().decode(
            FakeScript.self, from: try JSONSerialization.data(withJSONObject: document))
        self.runs = runs
        self.held = held
    }

    /// The template charter with the spec's overrides.
    static func charter(_ spec: StewardSpec, templates: URL, adapter: String) throws -> Data {
        let file = templates.appendingPathComponent("\(spec.template).json")
        guard
            var charter = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                as? [String: Any]
        else { throw DemoError("template \(spec.template) is not an object") }
        charter["id"] = spec.id
        charter["name"] = spec.name
        charter["department"] = spec.department
        charter["adapter"] = adapter
        charter["autonomy"] = "act_medium"
        charter["owner"] = spec.people.first?.id
        if let outcome = spec.outcome { charter["outcome"] = outcome }
        if let metric = spec.metric {
            charter["metric"] = [
                "name": metric.name, "target": metric.target, "unit": metric.unit,
                "direction": metric.direction,
            ]
        }
        var bindings = charter["bindings"] as? [[String: Any]] ?? []
        if let binding = spec.binding {
            bindings = [
                [
                    "id": binding.id, "kind": "mcp", "command": binding.command, "args": [],
                    "read": binding.read, "actions": binding.actions,
                ]
            ]
        }
        for person in spec.people {
            bindings.append([
                "id": person.id, "kind": "person", "channel": "inbox", "name": person.name,
                "role": person.role,
            ])
        }
        charter["bindings"] = bindings
        if let rules = spec.rules {
            var policy = charter["policy"] as? [String: Any] ?? [:]
            policy["rules"] = rules.map {
                ["action": $0.action, "decision": $0.decision, "note": $0.note]
            }
            charter["policy"] = policy
        }
        if let guardrails = spec.guardrails { charter["guardrails"] = guardrails }
        return try JSONSerialization.data(withJSONObject: charter, options: [.sortedKeys])
    }

    /// The binding an action kind belongs to.
    static func binding(_ spec: StewardSpec, kind: String, charter: [String: Any]) -> String {
        if let binding = spec.binding { return binding.id }
        let bindings = charter["bindings"] as? [[String: Any]] ?? []
        return bindings.first { ($0["actions"] as? [String])?.contains(kind) == true }?["id"]
            as? String ?? "inbox"
    }

    static func response(
        _ spec: StewardSpec, charter: [String: Any], number: Int, detail: String,
        value: Double, held: Bool, replanned: Bool = false, rng: inout SeededGenerator
    ) -> [String: Any] {
        let item = "\(spec.prefix)-\(number)"
        let choice = spec.choices[number % spec.choices.count]
        let metric = (charter["metric"] as? [String: Any])?["name"] as? String ?? "metric"
        let tool = spec.tool
        var actions: [[String: Any]] = [
            [
                "id": "a1", "kind": spec.autoKind,
                "binding": binding(spec, kind: spec.autoKind, charter: charter),
                "target": "\(spec.prefix.lowercased()):\(item)",
                "params": ["text": "\(choice): \(detail)"], "risk": "low",
                "why": "Keeps \(item) moving without waiting on anyone.",
            ]
        ]
        if held, let ask = spec.askKind {
            actions.append([
                "id": "a2", "kind": ask, "binding": binding(spec, kind: ask, charter: charter),
                "target": "\(spec.prefix.lowercased()):\(item)",
                "params": ["text": "Drafted for \(item): \(detail.lowercased())."],
                "risk": "medium",
                "why": "This reaches people outside the team, so a person signs off first.",
            ])
        }
        let tokens = Int.random(in: 1800...9000, using: &rng)
        return [
            "events": [
                ["kind": "status", "state": "working", "detail": "reading \(item)"],
                ["kind": "tool_call", "id": "t1", "tool": tool, "input": ["id": item]],
                [
                    "kind": "tool_result", "id": "t1", "isError": false,
                    "output": ["id": item, "summary": detail],
                ],
                [
                    "kind": "message", "role": "assistant",
                    "text": "\(item): \(detail). I'd mark it \(choice).",
                ],
            ],
            "status": "completed",
            "cost": [
                "inputTokens": tokens, "outputTokens": tokens / 6,
                "costMicros": tokens * 3 + tokens / 6 * 15,
            ],
            "result": [
                "summary": "\(item) (\(detail.lowercased())): \(choice).",
                "plan": [
                    [
                        "id": "p1", "text": "Work every new \(spec.prefix) item the day it arrives",
                        "status": "in_progress",
                        "rationale": "The outcome is measured on same-day handling.",
                    ],
                    [
                        "id": "p2", "text": "Catch items that went quiet for a week",
                        "status": "pending", "rationale": "Quiet items are where misses hide.",
                    ],
                ]
                    + (replanned
                        ? [
                            [
                                "id": "p3",
                                "text":
                                    "Answer pricing questions from larger teams within two hours",
                                "status": "in_progress",
                                "rationale":
                                    "Large-team pricing questions waited the longest last week.",
                            ]
                        ] : []),
                "decisions": [
                    [
                        "id": "d1", "choice": choice, "rationale": detail.lowercased(),
                        "why": "\(detail) usually means \(choice).",
                    ]
                ],
                "actions": actions,
                "measurements": [["metric": metric, "value": value]],
            ],
        ]
    }

    static func failure(_ spec: StewardSpec, number: Int) -> [String: Any] {
        [
            "events": [
                [
                    "kind": "status", "state": "working",
                    "detail": "reading \(spec.prefix)-\(number)",
                ],
                [
                    "kind": "tool_call", "id": "t1", "tool": spec.tool,
                    "input": ["id": "\(spec.prefix)-\(number)"],
                ],
                [
                    "kind": "tool_result", "id": "t1", "isError": true,
                    "output": ["error": "the \(spec.tool) call timed out"],
                ],
                [
                    "kind": "error",
                    "message": "\(spec.tool) timed out twice; giving up on this run",
                ],
            ],
            "status": "failed",
        ]
    }

    /// The input of the run `just snapshot` keeps in progress.
    static func liveInput(_ spec: StewardSpec) -> String {
        "\(spec.prefix)-LIVE: Pricing question from a 200-seat team"
    }

    /// A run that streams tool calls for a while, then works for a long time: in progress for
    /// as long as its process lives.
    static func live(_ spec: StewardSpec) -> [String: Any] {
        var steps: [[String: Any]] = []
        let tools = [
            ("crm.search", ["query": "200-seat team"]), ("crm.get", ["id": "LEAD-LIVE"]),
            ("crm.search", ["query": "similar deals this quarter"]),
        ]
        for (index, (tool, input)) in tools.enumerated() {
            steps.append([
                "event": ["kind": "tool_call", "id": "t\(index)", "tool": tool, "input": input]
            ])
            steps.append(["sleepMs": 1500])
            steps.append([
                "event": [
                    "kind": "tool_result", "id": "t\(index)", "isError": false,
                    "output": ["found": index + 2],
                ]
            ])
        }
        steps.append([
            "event": [
                "kind": "message", "role": "assistant",
                "text": "Three similar teams bought the annual plan; drafting a reply with it.",
            ]
        ])
        steps.append(["sleepMs": 1_800_000])
        return [
            "events": [
                ["kind": "status", "state": "working", "detail": "reading the pricing question"]
            ],
            "steps": steps, "status": "completed",
            "result": ["summary": "Answered the pricing question.", "actions": []],
        ]
    }

    static func reply(_ spec: StewardSpec, _ text: String) -> [String: Any] {
        [
            "events": [
                ["kind": "status", "state": "working", "detail": "looking into it"],
                [
                    "kind": "message", "role": "assistant",
                    "text": "On it. I checked \(spec.prefix) items from the last week.",
                ],
            ],
            "status": "completed",
            "result": [
                "summary": "Answered: \(text)",
                "decisions": [
                    ["id": "d1", "choice": "answered", "why": "A person asked directly."]
                ],
                "actions": [],
            ],
        ]
    }
}

struct DemoError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
