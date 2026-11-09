import Foundation

/// What a run decided and proposed, in the fields the default scorer compares.
struct CaseOutcome: Hashable, Sendable {
    var decisions: [String]
    /// "kind target", for example "label tracker:ISSUE-7".
    var actions: [String]

    /// Reads a case's `expected` object: `{decisions: [{choice}], actions: [{kind, target}]}`.
    static func expected(_ json: FeatureJSON) -> CaseOutcome {
        CaseOutcome(
            decisions: json["decisions"]?.array?.compactMap { $0["choice"]?.string } ?? [],
            actions: json["actions"]?.array?.map(action) ?? [])
    }

    /// What one rehearsal run actually did, from its `run.decision` and `action.proposed`.
    static func actual(events: [FeatureEvent], run: String) -> CaseOutcome {
        var outcome = CaseOutcome(decisions: [], actions: [])
        for event in events where event.run == run {
            switch event.type {
            case "run.decision":
                let decision = event.payload["decision"] ?? event.payload
                if let choice = decision["choice"]?.string { outcome.decisions.append(choice) }
            case "action.proposed":
                outcome.actions.append(action(event.payload["action"] ?? [:]))
            default: continue
            }
        }
        return outcome
    }

    private static func action(_ json: FeatureJSON) -> String {
        let kind = json["kind"]?.string ?? "action"
        guard let target = json["target"]?.string, !target.isEmpty else { return kind }
        return "\(kind) \(target)"
    }
}

/// One sample's score.
struct SampleScore: Hashable, Sendable {
    var value: Double
    var passed: Bool
    var notes: [String]
}

/// A correction a person recorded for a case.
struct CorrectionRecord: Hashable, Sendable {
    var text: String
    var expected: FeatureJSON?
    var by: FeatureActor
    var at: Date
}

/// One case's result in a rehearsal.
struct CaseResult: Identifiable, Hashable, Sendable {
    var id: String
    var runs: [String?]
    var scores: [SampleScore]
    var leak: Bool
    var corrections: [CorrectionRecord] = []
    /// Each sample's result in the shape of `expected`; empty in events recorded before
    /// results were kept, and `nil` where a sample's run failed.
    var results: [FeatureJSON?] = []

    var passed: Bool { !leak && !scores.isEmpty && scores.allSatisfy(\.passed) }
    var meanValue: Double {
        scores.isEmpty ? 0 : scores.map(\.value).reduce(0, +) / Double(scores.count)
    }
    var notes: [String] { scores.flatMap(\.notes) }
    /// The first run that recorded anything, for the actual outcome.
    var firstRun: String? { runs.compactMap { $0 }.first }
    /// The latest corrected expected result, if a correction set one.
    var correctedExpected: FeatureJSON? {
        corrections.last(where: { $0.expected != nil })?.expected
    }
}

/// A rehearsal: what it ran, how it scored, and each case.
struct RehearsalItem: Identifiable, Hashable, Sendable {
    struct Totals: Hashable, Sendable {
        var meanScore: Double
        var passed: Int
        var leaks: Int
    }

    var id: String
    var steward: String?
    var charterVersion: Int
    var casebook: String
    var caseCount: Int
    var samples: Int
    var proposal: String?
    var startedAt: Date
    var totals: Totals?
    var cases: [CaseResult] = []

    var isFinished: Bool { totals != nil }
}

/// A person's `steward.ready` mark.
struct ReadyRecord: Hashable, Sendable {
    var steward: String
    var charterVersion: Int
    var rehearsal: String?
    var by: FeatureActor
    var at: Date
}

/// A steward's rehearsals, newest first, with readiness marks.
struct RehearsalList: Hashable, Sendable {
    var rehearsals: [RehearsalItem]
    var ready: [ReadyRecord]

    /// Reads AryaEval's `rehearsal.*`, `case.corrected`, and `steward.ready` payloads.
    static func build(events: [FeatureEvent], steward: String? = nil) -> RehearsalList {
        var items: [String: RehearsalItem] = [:]
        var order: [String] = []
        var corrections: [String: [CorrectionRecord]] = [:]
        var ready: [ReadyRecord] = []
        for event in events where steward == nil || event.steward == steward {
            let p = event.payload
            switch event.type {
            case "rehearsal.started":
                guard let id = p["rehearsal"]?.string else { continue }
                items[id] = started(id, event)
                order.append(id)
            case "rehearsal.case.scored":
                guard let id = p["rehearsal"]?.string, let caseID = p["case"]?.string else {
                    continue
                }
                items[id]?.cases.append(scored(caseID, p))
            case "rehearsal.finished":
                guard let id = p["rehearsal"]?.string else { continue }
                items[id]?.totals = RehearsalItem.Totals(
                    meanScore: p["meanScore"]?.number ?? 0,
                    passed: Int(p["passed"]?.number ?? 0), leaks: Int(p["leaks"]?.number ?? 0))
            case "case.corrected":
                guard let casebook = p["casebook"]?.string, let caseID = p["case"]?.string else {
                    continue
                }
                corrections["\(casebook)/\(caseID)", default: []].append(
                    CorrectionRecord(
                        text: p["text"]?.string ?? "", expected: p["expected"], by: event.actor,
                        at: event.at))
            case "steward.ready":
                guard let id = event.steward else { continue }
                ready.append(
                    ReadyRecord(
                        steward: id, charterVersion: Int(p["charterVersion"]?.number ?? 0),
                        rehearsal: p["rehearsal"]?.string, by: event.actor, at: event.at))
            default: continue
            }
        }
        let all = order.reversed().compactMap { id -> RehearsalItem? in
            guard var item = items[id] else { return nil }
            for index in item.cases.indices {
                item.cases[index].corrections =
                    corrections["\(item.casebook)/\(item.cases[index].id)"] ?? []
            }
            return item
        }
        return RehearsalList(rehearsals: all, ready: ready)
    }

    /// The latest ready mark for a steward's charter version, if any.
    func readyMark(steward: String?, charterVersion: Int) -> ReadyRecord? {
        ready.last { $0.steward == steward && $0.charterVersion == charterVersion }
    }

    /// Mark ready is offered for a finished rehearsal of a live charter (not a proposal's
    /// candidate) whose version is not already marked ready.
    func canMarkReady(_ item: RehearsalItem) -> Bool {
        item.isFinished && item.proposal == nil && item.steward != nil
            && readyMark(steward: item.steward, charterVersion: item.charterVersion) == nil
    }

    private static func started(_ id: String, _ event: FeatureEvent) -> RehearsalItem {
        let p = event.payload
        return RehearsalItem(
            id: id, steward: event.steward, charterVersion: Int(p["charterVersion"]?.number ?? 0),
            casebook: p["casebookVersion"]?.string ?? "", caseCount: Int(p["cases"]?.number ?? 0),
            samples: Int(p["samples"]?.number ?? 1), proposal: p["proposal"]?.string,
            startedAt: event.at)
    }

    private static func scored(_ caseID: String, _ p: FeatureJSON) -> CaseResult {
        let scores =
            p["scores"]?.array?.map { score in
                SampleScore(
                    value: score["value"]?.number ?? 0, passed: score["passed"]?.bool ?? false,
                    notes: score["notes"]?.strings ?? [])
            } ?? []
        let runs = p["runs"]?.array?.map(\.string) ?? []
        let results = p["results"]?.array?.map { $0 == .null ? nil : $0 } ?? []
        return CaseResult(
            id: caseID, runs: runs, scores: scores, leak: p["leak"]?.bool ?? false,
            results: results)
    }
}

/// Text for the rehearsals view, kept apart from layout so it can be tested.
enum RehearsalsText {
    /// "Mean 0.50 · 1 of 3 passed · 1 leak", or "Running, 2 of 3 cases scored".
    static func totals(_ item: RehearsalItem) -> String {
        guard let totals = item.totals else {
            return "Running, \(item.cases.count) of \(item.caseCount) cases scored"
        }
        var text = "Mean \(ChangesText.score(totals.meanScore)) · \(totals.passed) of "
        text += "\(item.caseCount) passed"
        if totals.leaks > 0 { text += " · \(totals.leaks) leak" + (totals.leaks == 1 ? "" : "s") }
        return text
    }

    /// "charter v1 on casebook cb0001 · 1 sample", with "for proposal pr_1" when relevant.
    static func meta(_ item: RehearsalItem) -> String {
        let book = RoutinesText.shortVersion(item.casebook)
        var text = "charter v\(item.charterVersion) on casebook \(book)"
        text += " · \(item.samples) sample" + (item.samples == 1 ? "" : "s")
        if let proposal = item.proposal { text += " · for proposal \(proposal)" }
        return text
    }

    /// The case's status word: "passed", "failed", or "leak".
    static func status(_ result: CaseResult) -> String {
        result.leak ? "leak" : (result.passed ? "passed" : "failed")
    }

    /// "Ready since 2m ago, marked by local".
    static func ready(_ mark: ReadyRecord, now: Date) -> String {
        "Ready since \(FeatureTime.relative(mark.at, now: now)), marked by \(mark.by.id)"
    }
}

extension CaseOutcome {
    /// "chose billing; label inbox:MSG-1, route inbox:MSG-1", or "nothing".
    var text: String {
        var parts: [String] = []
        if !decisions.isEmpty { parts.append("chose " + decisions.joined(separator: ", ")) }
        if !actions.isEmpty { parts.append(actions.joined(separator: ", ")) }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }
}

/// A recorded result in a few words, the same rules as the evaluator's result text:
/// decisions as their choices, actions as "kind target", other scalar fields as "key value";
/// `summary` and structured fields are left out.
enum ResultWords {
    static func describe(_ result: FeatureJSON?) -> String {
        guard let result else { return "no result" }
        guard case .object(let members) = result else { return value(result) }
        var parts: [String] = []
        if let decisions = members["decisions"]?.array, !decisions.isEmpty {
            parts.append("chose " + decisions.map(value).joined(separator: ", "))
        }
        if let actions = members["actions"]?.array, !actions.isEmpty {
            parts.append(actions.map(value).joined(separator: ", "))
        }
        for key in members.keys.sorted() where !["decisions", "actions", "summary"].contains(key) {
            guard let item = members[key] else { continue }
            switch item {
            case .string, .bool, .number: parts.append("\(key) \(value(item))")
            default: continue
            }
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }

    static func value(_ json: FeatureJSON) -> String {
        if let choice = json["choice"]?.string { return choice }
        if let kind = json["kind"]?.string {
            guard let target = json["target"]?.string, !target.isEmpty else { return kind }
            return "\(kind) \(target)"
        }
        return json.string ?? json.compactText
    }
}

/// Text for the Improve tab, kept apart from layout so it can be tested.
enum ImproveText {
    /// "8/8 passed · ready since 2m ago", "6/8 passed · 1 leak", or "Running, 2 of 8 scored".
    static func summary(_ item: RehearsalItem, ready: ReadyRecord?, now: Date) -> String {
        guard let totals = item.totals else {
            return "Running, \(item.cases.count) of \(item.caseCount) scored"
        }
        var text = "\(totals.passed)/\(item.caseCount) passed"
        if totals.leaks > 0 { text += " · \(totals.leaks) leak" + (totals.leaks == 1 ? "" : "s") }
        if let ready { text += " · ready since \(FeatureTime.relative(ready.at, now: now))" }
        return text
    }

    /// "charter v1 · casebook 1a2b3c", with "· for a proposal" when it rehearsed one.
    static func meta(_ item: RehearsalItem) -> String {
        var text = "charter v\(item.charterVersion) · casebook "
        text += RoutinesText.shortVersion(item.casebook)
        if item.proposal != nil { text += " · for a proposal" }
        return text
    }

    /// What the case's first sample would have done: its recorded result, else what its run
    /// recorded in the ledger.
    static func wouldHaveDone(_ result: CaseResult, events: [FeatureEvent]) -> String {
        if let recorded = result.results.compactMap({ $0 }).first {
            return ResultWords.describe(recorded)
        }
        guard let run = result.firstRun else { return "no result" }
        return CaseOutcome.actual(events: events, run: run).text
    }

    /// Scores add nothing when every case scored the same, so the column is hidden.
    static func showsScores(_ item: RehearsalItem) -> Bool {
        Set(item.cases.map(\.meanValue)).count > 1
    }

    /// "2h ago · 6/8 passed" for the history menu.
    static func historyLabel(_ item: RehearsalItem, now: Date) -> String {
        let when = FeatureTime.relative(item.startedAt, now: now)
        guard let totals = item.totals else { return "\(when) · running" }
        return "\(when) · \(totals.passed)/\(item.caseCount) passed"
    }
}
