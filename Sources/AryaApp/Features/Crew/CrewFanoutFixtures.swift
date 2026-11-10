import Foundation

/// A crew run in flight for previews and the `crew-fanout-live` snapshot: the host fanned out
/// to four delegates; one finished, two are working (one on an open tool call), and one was
/// refused by the crew's adapter allowlist.
enum CrewFanoutFixtures {
    static let host = "run_fan"

    /// The crew run's events for `steward`; prepend `steward.created` for a standalone log.
    static func live(now: Date, steward: String = PreviewFixtures.steward) -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: now.addingTimeInterval(-95))
        log.add(
            "run.started", steward: steward, run: host,
            ["input": ["kind": "message", "text": "Weekly digest: 14 open billing threads"]])
        log.add(
            "run.decision", steward: steward, run: host,
            [
                "decision": [
                    "id": "d1", "choice": "fan out",
                    "rationale": "Four threads need separate drafts; delegates work in parallel.",
                ]
            ])
        let delegates: [(String, String)] = [
            ("dl_1", "summarized the refund threads"), ("dl_2", "drafted the outage reply"),
            ("dl_3", "checked the invoice totals"),
        ]
        for (index, (id, title)) in delegates.enumerated() {
            let child = "\(host)\(Character(UnicodeScalar(97 + index)!))"
            log.add(
                "run.delegated", steward: steward, run: host, after: 1,
                [
                    "delegation": .string(id), "title": .string(title), "child": .string(child),
                    "adapter": "fake", "effort": "low",
                    "limits": ["maxTurns": 4, "timeoutSeconds": 120, "maxCostMicros": 200_000],
                ])
            log.add(
                "run.started", steward: steward, run: child, after: 0.5,
                ["input": ["kind": "message", "text": .string(title)], "parent": .string(host)])
        }
        log.add(
            "run.delegated", steward: steward, run: host, after: 1,
            [
                "delegation": "dl_4", "title": "looked up the customer in the browser",
                "refused": "adapter_not_allowed:browser",
            ])
        log.add(
            "run.tool.call", steward: steward, run: "\(host)a", after: 3,
            ["id": "t1", "tool": "inbox.search", "input": ["q": "refund"]])
        log.add(
            "run.tool.result", steward: steward, run: "\(host)a", after: 2,
            ["id": "t1", "isError": false, "durationSeconds": 2, "output": ["count": 6]])
        log.add(
            "run.decision", steward: steward, run: "\(host)a", after: 4,
            ["decision": ["id": "c1", "choice": "six refunds", "rationale": "All duplicates."]])
        log.add(
            "run.finished", steward: steward, run: "\(host)a", after: 1,
            ["status": "completed", "summary": "Six refund threads, all duplicate charges."])
        log.add(
            "run.decision", steward: steward, run: "\(host)b", after: 6,
            ["decision": ["id": "c1", "choice": "apologize", "rationale": "Known outage."]])
        log.add(
            "run.tool.call", steward: steward, run: "\(host)c", after: 3,
            ["id": "t1", "tool": "billing.invoices", "input": ["month": "2026-10"]])
        return log.events
    }
}
