import Arya
import AryaAdapters
import AryaCore
import Foundation

/// One timeline step. Steps run in time order (stable for equal times), because ledger times
/// never go backwards.
enum DemoStep {
    case setupTriage
    case setupExample(steward: String, folder: String)
    case create(GeneratedSteward)
    case run(steward: String, input: String)
    case pause(steward: String)
    case message(steward: String, person: String, intent: String, text: String)
    case propose(
        steward: String, change: (inout [String: Any]) -> Void, title: String, reason: String)
    case remember(text: String, steward: String?, person: String)
    case report(steward: String)
}

struct DemoSeeder {
    let home: URL
    let examples: URL
    let now: Date
    /// False seeds only the three example stewards (a quick check of the seeder itself).
    var fleet = true
    /// When set, every adapter profile paces the fake adapter (`ARYA_FAKE_PACE_MS`).
    var paceMillis: Int? = nil

    private var nowMillis: Int64 { Int64((now.timeIntervalSince1970 * 1000).rounded(.down)) }
    private var today: Int64 { nowMillis - nowMillis % 86_400_000 }
    private func at(daysAgo: Int, hour: Double) -> Int64 {
        today - Int64(daysAgo) * 86_400_000 + Int64(hour * 3_600_000)
    }

    /// Seeds the home and says what it holds.
    func seed() async throws -> String {
        try? FileManager.default.removeItem(at: home)
        var rng = SeededGenerator(0xA27A_DE30)
        let generated = try (fleet ? DemoStewards.all : []).map {
            try GeneratedSteward(
                $0, templates: examples.appendingPathComponent("templates"), today: today,
                rng: &rng)
        }
        var scripts: [String: FakeScript] = [:]
        for name in ["triage", "refunds", "digest"] {
            let script = try FakeScript.load(
                from: examples.appendingPathComponent("\(name)/fake-script.json"))
            scripts["fake-\(name)"] = script
        }
        for steward in generated { scripts[steward.adapter] = steward.script }
        try writeProfiles(generated)

        let start = Timestamp(millis: at(daysAgo: 60, hour: 0))
        let ambient = Ambient.fixed(start: start, stepMillis: 1, seed: 0xA27A)
        let workspace = try await Workspace.openForSeeding(
            home: home, ambient: ambient, scripts: scripts)
        var context = Context(
            workspace: workspace, ambient: ambient, nowMillis: nowMillis,
            held: generated.reduce(into: Set<String>()) { $0.formUnion($1.held) },
            generated: Set(generated.map(\.spec.id)))
        for (when, step) in try timeline(generated) {
            ambient.advance(to: Timestamp(millis: when))
            try await context.perform(step, examples: examples)
        }
        try await writeVisits(workspace)
        let runs = try await workspace.runs().count
        let pending = try await workspace.approvals().count
        let stewards = try await workspace.stewards().count
        return "\(stewards) stewards, \(runs) runs, \(pending) approvals waiting"
    }

    /// Every step with its time, sorted.
    private func timeline(_ generated: [GeneratedSteward]) throws -> [(Int64, DemoStep)] {
        var steps: [(Int64, DemoStep)] = [(at(daysAgo: 30, hour: 8), .setupTriage)]
        let triage = try lines(examples.appendingPathComponent("triage/history.txt"))
        for (index, message) in triage.enumerated() {
            let day = 29 - index
            steps.append(
                (
                    at(daysAgo: day, hour: Double(8 + day % 5)),
                    .run(steward: "st_triage", input: message)
                ))
        }
        steps.append(
            (at(daysAgo: 29, hour: 14), .setupExample(steward: "st_refunds", folder: "refunds")))
        steps.append(
            (at(daysAgo: 29, hour: 14.5), .setupExample(steward: "st_digest", folder: "digest")))
        for (folder, steward, hour) in [
            ("refunds", "st_refunds", 13.5), ("digest", "st_digest", 7.5),
        ] {
            for line in try lines(examples.appendingPathComponent("\(folder)/history.txt")) {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, let days = Int(parts[0]) else { continue }
                steps.append(
                    (at(daysAgo: days, hour: hour), .run(steward: steward, input: parts[1])))
            }
        }
        steps.append((at(daysAgo: 2, hour: 16), .pause(steward: "st_digest")))
        for (offset, message) in [
            "New message MSG-102: App crashes on export",
            "New message MSG-202: Where is my package?",
            "New message MSG-203: Damaged order, please refund",
        ].enumerated() {
            steps.append(
                (
                    at(daysAgo: 1, hour: 15) + Int64(offset) * 60_000,
                    .run(steward: "st_triage", input: message)
                ))
        }

        for steward in generated {
            let spec = steward.spec
            steps.append((at(daysAgo: spec.days + 1, hour: 9), .create(steward)))
            for run in steward.runs {
                steps.append((run.at, .run(steward: spec.id, input: run.input)))
            }
            for message in spec.messages {
                steps.append(
                    (
                        at(daysAgo: message.days, hour: 10.5),
                        .message(
                            steward: spec.id, person: message.person, intent: message.intent,
                            text: message.text)
                    ))
            }
        }
        // People at work on the examples (connect lane): Sam and Priya ask, correct, and hand
        // off work, and reports go out; the example scripts answer the asks and hand-offs.
        for (when, steward, person, intent, text) in [
            (
                at(daysAgo: 3, hour: 10), "st_triage", "person:sam", "ask",
                "How many refund requests came in this week?"
            ),
            (
                at(daysAgo: 3, hour: 11), "st_triage", "person:sam", "correct",
                "Duplicate charges always go to billing, even when shipping is mentioned."
            ),
            (
                at(daysAgo: 2, hour: 14), "st_refunds", "person:priya", "ask",
                "Which approved refunds are still unconfirmed?"
            ),
            (
                at(daysAgo: 1, hour: 11), "st_refunds", "person:priya", "handoff",
                "Follow up on ORDER-1043 with the customer."
            ),
            (
                at(daysAgo: 1, hour: 16), "st_triage", "person:priya", "handoff",
                "Check that every duplicate-charge refund went out."
            ),
        ] {
            steps.append(
                (when, .message(steward: steward, person: person, intent: intent, text: text)))
        }
        steps.append((at(daysAgo: 2, hour: 17), .report(steward: "st_refunds")))
        steps.append((at(daysAgo: 1, hour: 9), .report(steward: "st_triage")))
        guard fleet else { return sorted(steps + newest()) }
        // Proposals waiting on a person, each a charter diff.
        steps.append(
            (
                at(daysAgo: 1, hour: 11),
                .propose(
                    steward: "st_lead_follow_up",
                    change: { charter in
                        var guardrails = charter["guardrails"] as? [String] ?? []
                        guardrails.append("Never email a lead more than twice in a week.")
                        charter["guardrails"] = guardrails
                    },
                    title: "Cap follow-up emails",
                    reason: "Two leads unsubscribed after three emails in five days.")
            ))
        steps.append(
            (
                at(daysAgo: 0, hour: 7),
                .propose(
                    steward: "st_invoice_chasing",
                    change: { charter in
                        var metric = charter["metric"] as? [String: Any] ?? [:]
                        metric["target"] = 0.8
                        charter["metric"] = metric
                    },
                    title: "Lower the chase target to 80% for the quarter end",
                    reason: "Quarter-end volume doubles; the team agreed on 80% until it clears.")
            ))
        steps.append(
            (
                at(daysAgo: 6, hour: 12),
                .remember(
                    text: "Enterprise customers prefer a call before any email about money.",
                    steward: nil, person: "local")
            ))
        steps.append(
            (
                at(daysAgo: 3, hour: 16),
                .remember(
                    text: "Renewals over 50k go to the finance lead, not the budget owner.",
                    steward: "st_vendor_spend_review", person: "local")
            ))
        return sorted(steps + newest())
    }

    /// The demo's newest moments: a quiet check about two hours ago (the last look lands after
    /// it, `writeVisits`), a triage run, and Sam handing off MSG-140, now.
    private func newest() -> [(Int64, DemoStep)] {
        [
            (nowMillis - 7_200_000, .run(steward: "st_refunds", input: "Check approved refunds")),
            (
                nowMillis - 120_000,
                .run(
                    steward: "st_triage",
                    input: "New message MSG-201: Refund for a duplicate charge")
            ),
            (
                nowMillis - 60_000,
                .message(
                    steward: "st_triage", person: "person:sam", intent: "handoff",
                    text: "Take MSG-140 and close it out with the customer.")
            ),
        ]
    }

    /// Steps up to now, in time order; equal times keep their order.
    private func sorted(_ steps: [(Int64, DemoStep)]) -> [(Int64, DemoStep)] {
        steps.filter { $0.0 <= nowMillis }.enumerated()
            .sorted {
                $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset
            }
            .map(\.element)
    }

    private func lines(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }
    }

    /// `adapters.json` for live runs in the app: the examples' profiles with absolute paths,
    /// and one per generated steward serving its script from `<home>/demo/`.
    private func writeProfiles(_ generated: [GeneratedSteward]) throws {
        let bin = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let fake = bin.appendingPathComponent("arya-fake-adapter").path
        let scripts = home.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        var profiles: [String: Any] = [:]
        func profile(_ script: String) -> [String: Any] {
            let args = ["--script", script]
            var entry: [String: Any] = [
                "command": fake, "args": ["low": args, "medium": args, "high": args],
            ]
            if let paceMillis { entry["env"] = ["ARYA_FAKE_PACE_MS": "\(paceMillis)"] }
            return entry
        }
        for name in ["triage", "refunds", "digest"] {
            profiles["fake-\(name)"] = profile(
                examples.appendingPathComponent("\(name)/fake-script.json").path)
        }
        for steward in generated {
            let file = scripts.appendingPathComponent("\(steward.adapter).json")
            try JSONEncoder().encode(steward.script).write(to: file)
            profiles[steward.adapter] = profile(file.path)
        }
        let document: [String: Any] = ["v": 1, "profiles": profiles]
        try JSONSerialization.data(
            withJSONObject: document, options: [.sortedKeys, .prettyPrinted]
        )
        .write(to: home.appendingPathComponent("adapters.json"))
    }

    /// The person's last look: the newest seq at least two hours before the newest event, per
    /// steward, in `<home>/app/visits.json`.
    private func writeVisits(_ workspace: Workspace) async throws {
        let entries = try await workspace.ledger()
        guard let newest = entries.last?.at else { return }
        let cutoff = newest.addingTimeInterval(-7200)
        let seen = entries.last { $0.at <= cutoff }?.seq ?? 0
        let stewards = try await workspace.stewards().map(\.id)
        let document: [String: Any] = [
            "v": 1, "lastSeen": Dictionary(uniqueKeysWithValues: stewards.map { ($0, seen) }),
        ]
        let folder = home.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("visits.json"))
    }
}

/// What carrying out steps needs: the workspace, the clock, and how many held approvals each
/// steward still has waiting.
struct Context {
    let workspace: Workspace
    let ambient: Ambient
    let nowMillis: Int64
    /// Generated inputs whose runs hold an action; other generated runs hold nothing.
    let held: Set<String>
    let generated: Set<String>
    var decided = 0

    mutating func perform(_ step: DemoStep, examples: URL) async throws {
        switch step {
        case .setupTriage:
            let folder = examples.appendingPathComponent("triage")
            func file(_ name: String) throws -> Data {
                try Data(contentsOf: folder.appendingPathComponent(name))
            }
            _ = try await workspace.createSteward(charter: try file("charter.json"))
            _ = try await workspace.importCasebook(
                steward: "st_triage", data: try file("casebook.jsonl"), name: "casebook")
            _ = try await workspace.rehearse(steward: "st_triage")
            // charter v2: case-0006 improves, case-0005 regresses.
            let proposal = try await workspace.proposeCharter(
                steward: "st_triage", charter: try file("charter-v2.json"), baseVersion: 1)
            _ = try await workspace.checkProposal(proposal.id)
            let expected = try await workspace.expected(
                steward: "st_triage", case: "case-0006", choice: "billing")
            _ = try await workspace.correct(
                steward: "st_triage", case: "case-0006", expected: expected,
                note: "A question about the card on file is a billing question.")
            _ = try await workspace.rehearse(steward: "st_triage")
            _ = try await workspace.markReady(steward: "st_triage")
            _ = try await workspace.importHistory(
                steward: "st_triage", data: try file("history-export.json"),
                source: "history-export.json")
            _ = try await workspace.rehearse(steward: "st_triage")
            _ = try await workspace.reviewCase(
                steward: "st_triage", case: "hist-MSG-110", verdict: "agree")
        case .setupExample(let steward, let name):
            let folder = examples.appendingPathComponent(name)
            _ = try await workspace.createSteward(
                charter: try Data(contentsOf: folder.appendingPathComponent("charter.json")))
            _ = try await workspace.importCasebook(
                steward: steward,
                data: try Data(contentsOf: folder.appendingPathComponent("casebook.jsonl")),
                name: "casebook")
            _ = try await workspace.rehearse(steward: steward)
            _ = try await workspace.markReady(steward: steward)
        case .create(let steward):
            _ = try await workspace.createSteward(charter: steward.charter)
            _ = try await workspace.markReady(steward: steward.spec.id)
        case .run(let steward, let input):
            let run = try await workspace.startRun(steward: steward, input: input)
            if !generated.contains(steward) || held.contains(input) { try await settle(run) }
        case .pause(let steward):
            try await workspace.pauseSteward(steward)
        case .message(let steward, let person, let intent, let text):
            let receipt = try await workspace.message(
                steward: steward, text: text, intent: intent, by: person)
            if let run = receipt.run { try await settle(run) }
        case .propose(let steward, let change, let title, let reason):
            let live: Data = try await workspace.charter(steward)
            var charter = try JSONSerialization.jsonObject(with: live) as? [String: Any] ?? [:]
            change(&charter)
            let version = try await workspace.steward(steward)?.charterVersion ?? 1
            _ = try await workspace.proposeCharter(
                steward: steward,
                charter: try JSONSerialization.data(
                    withJSONObject: charter, options: [.sortedKeys]),
                baseVersion: version, title: title, reason: reason)
        case .remember(let text, let steward, let person):
            _ = try await workspace.remember(text, steward: steward, by: person)
        case .report(let steward):
            _ = try await workspace.sendReport(steward: steward)
        }
    }

    /// Decides what a run held: approvals older than a day and a half were decided by a person
    /// about 40 minutes later (one in seven denied); newer ones still wait.
    private mutating func settle(_ run: RunSummary) async throws {
        let started = Int64((run.startedAt.timeIntervalSince1970 * 1000).rounded(.down))
        guard nowMillis - started > 36 * 3_600_000 else { return }
        let held = try await workspace.approvals().filter { $0.run == run.id }
        guard !held.isEmpty else { return }
        ambient.advance(to: Timestamp(millis: started + 40 * 60_000))
        for approval in held {
            decided += 1
            if decided % 7 == 0 {
                _ = try await workspace.deny(approval.id, note: "Not this one; I'll handle it.")
            } else {
                _ = try await workspace.approve(approval.id)
            }
        }
    }
}
