import AryaCore
import AryaRuntime

/// Event type of a new version of a steward's learned checks.
public enum LearnedCheckEventType {
    /// `checks.built`: the checks people taught a steward through corrections and agreements
    /// changed; the payload holds the whole new version.
    public static let built = "checks.built"
}

/// One check a person taught the steward: a rubric check on one case, in that person's words.
public struct LearnedCheck: Hashable, Sendable, Codable {
    public enum Origin: String, Hashable, Sendable, Codable {
        /// From `case.corrected`: the person said what the steward should have done.
        case corrected
        /// From `case.reviewed` agreed: the person confirmed what the case expects.
        case agreed
    }

    /// `<case>/<path>=<value>`, stable across versions.
    public var id: String
    public var caseID: CaseID
    /// The person's note for a correction, else the expectation in words.
    public var text: String
    public var check: RubricCheck
    public var origin: Origin
    /// The person, for example `local` or `person:sam`.
    public var by: String

    public init(
        id: String, caseID: CaseID, text: String, check: RubricCheck, origin: Origin, by: String
    ) {
        self.id = id
        self.caseID = caseID
        self.text = text
        self.check = check
        self.origin = origin
        self.by = by
    }

    enum CodingKeys: String, CodingKey {
        case id, text, check, origin, by
        case caseID = "case"
    }
}

/// Payload of `checks.built` (actor: whoever asked for the build).
public struct ChecksBuiltPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    /// 1, 2, 3, … per steward.
    public var version: Int
    public var checks: [LearnedCheck]
    /// Check ids new in this version, and those the previous version had and this one drops.
    public var added: [String]
    public var removed: [String]

    public init(version: Int, checks: [LearnedCheck], added: [String], removed: [String]) {
        self.version = version
        self.checks = checks
        self.added = added
        self.removed = removed
    }
}

/// One learned check against the newest live rehearsal.
public struct LearnedCheckResult: Hashable, Sendable, Codable {
    public var check: LearnedCheck
    /// `nil` when the rehearsal has no answer for the check's case.
    public var passed: Bool?
    /// What the steward did on that field: `choice: billing`, or `not rehearsed`.
    public var found: String
    /// The result in one line, shown verbatim: `Keeps “…” on case-0006.`,
    /// `Breaks “…” on case-0006: choice: bug, not billing.`, or
    /// `“…” on case-0006: not rehearsed yet.`
    public var result: String
}

/// A steward's learned checks, scored: what the app's Improve tab and `arya checks` show.
public struct LearnedChecksView: Hashable, Sendable, Codable {
    public var steward: String
    /// The newest recorded version, or 0 before the first build.
    public var version: Int
    /// The live rehearsal the answers come from, if any.
    public var rehearsal: String?
    /// Failing checks first, then unscored, then passing.
    public var results: [LearnedCheckResult]
    public var total: Int
    public var scored: Int
    public var passed: Int
    /// Ids added and removed by the newest version.
    public var added: [String]
    public var removed: [String]
    /// One sentence, shown verbatim: `Checks v2: passes 8 of 9; misses “…” on case-0006.`
    public var sentence: String
}

/// Builds versioned rubric checks from corrections and agreements and scores the steward on
/// them. Deterministic: the same ledger always derives the same checks.
public struct LearnedChecks: Sendable {
    public var sink: any EventSink
    public var casebooks: any CasebookSource

    public init(sink: any EventSink, casebooks: any CasebookSource) {
        self.sink = sink
        self.casebooks = casebooks
    }

    /// Records a new version when the derived checks differ from the newest recorded version,
    /// and returns the newest version either way.
    @discardableResult
    public func build(steward: StewardID, actor: RuntimeActor = .localUser) async throws
        -> ChecksBuiltPayload
    {
        let events = try await sink.events(from: 1)
        let derived = try await derive(events, steward: steward)
        let latest = try Self.latest(events, steward: steward)
        if let latest, latest.checks == derived { return latest }
        let before = Set(latest?.checks.map(\.id) ?? [])
        let now = Set(derived.map(\.id))
        let payload = ChecksBuiltPayload(
            version: (latest?.version ?? 0) + 1, checks: derived,
            added: derived.map(\.id).filter { !before.contains($0) },
            removed: (latest?.checks.map(\.id) ?? []).filter { !now.contains($0) })
        if latest == nil && derived.isEmpty { return payload }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: LearnedCheckEventType.built, steward: steward, run: nil, actor: actor,
                payload: try CanonicalJSON.jsonValue(payload)))
        return payload
    }

    /// The newest recorded version scored on the newest finished live rehearsal; `nil` before
    /// the first build.
    public func view(steward: StewardID) async throws -> LearnedChecksView? {
        let events = try await sink.events(from: 1)
        guard let latest = try Self.latest(events, steward: steward) else { return nil }
        var answers: [CaseID: JSONValue] = [:]
        let rehearsal = try ReviewQueue.latestLiveRehearsal(events, steward: steward)
        if let rehearsal {
            let report = try await RehearsalReports(sink: sink, casebooks: casebooks)
                .report(rehearsal)
            for item in report.cases {
                if let actual = item.samples.first?.actual { answers[item.caseID] = actual }
            }
        }
        return Self.score(
            latest, answers: answers, steward: steward, rehearsal: rehearsal?.rawValue)
    }

    static func score(
        _ built: ChecksBuiltPayload, answers: [CaseID: JSONValue], steward: StewardID,
        rehearsal: String?
    ) -> LearnedChecksView {
        let results = built.checks.map { learned -> LearnedCheckResult in
            let quoted = "“\(quote(learned.text))” on \(learned.caseID.rawValue)"
            guard let actual = answers[learned.caseID] else {
                return LearnedCheckResult(
                    check: learned, passed: nil, found: "not rehearsed",
                    result: "\(quoted): not rehearsed yet.")
            }
            let holds = learned.check.holds(expected: .null, actual: actual)
            let found = actual.values(at: learned.check.path)
            let name = RubricCheck.name(learned.check.path)
            let phrase = learned.check.phrase(holds: false, found: found)
            return LearnedCheckResult(
                check: learned, passed: holds,
                found: found.isEmpty ? "no \(name)" : "\(name): \(CaseScore.words(found))",
                result: holds ? "Keeps \(quoted)." : "Breaks \(quoted): \(phrase).")
        }
        func rank(_ item: LearnedCheckResult) -> Int {
            switch item.passed {
            case false?: return 0
            case nil: return 1
            case true?: return 2
            }
        }
        let ordered = results.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        let scored = results.filter { $0.passed != nil }.count
        let passed = results.filter { $0.passed == true }.count
        return LearnedChecksView(
            steward: steward.rawValue, version: built.version, rehearsal: rehearsal,
            results: ordered, total: results.count, scored: scored, passed: passed,
            added: built.added, removed: built.removed,
            sentence: sentence(version: built.version, results: ordered, scored: scored))
    }

    /// `Checks v2: passes 8 of 9; misses “…” on case-0006 and 1 more.`
    static func sentence(version: Int, results: [LearnedCheckResult], scored: Int) -> String {
        let head = "Checks v\(version)"
        guard !results.isEmpty else {
            return "\(head): none yet; correct or agree with cases in the review queue."
        }
        let noun = results.count == 1 ? "check" : "checks"
        guard scored > 0 else {
            return "\(head): \(results.count) \(noun) from people's reviews, not rehearsed yet."
        }
        let failing = results.filter { $0.passed == false }
        let passed = results.filter { $0.passed == true }.count
        let unscored = results.count - scored
        let rest = unscored > 0 ? " (\(unscored) not rehearsed)" : ""
        guard let first = failing.first else {
            return scored == results.count
                ? "\(head): passes all \(results.count) \(noun) people taught it."
                : "\(head): passes \(passed) of \(results.count)\(rest)."
        }
        let more = failing.count > 1 ? " and \(failing.count - 1) more" : ""
        let quoted = quote(first.check.text)
        return "\(head): passes \(passed) of \(results.count)\(rest); misses “\(quoted)” on "
            + "\(first.check.caseID.rawValue)\(more)."
    }

    /// The text without its closing period, for quoting inside a sentence.
    static func quote(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// The newest `checks.built` of a steward.
    static func latest(_ events: [RuntimeEvent], steward: StewardID) throws
        -> ChecksBuiltPayload?
    {
        guard
            let event = events.last(where: {
                $0.type == LearnedCheckEventType.built && $0.draft.steward == steward
            })
        else { return nil }
        return try EvalPayload.decode(ChecksBuiltPayload.self, event.payload)
    }

    /// Every case's latest review decides: a correction teaches its expectation in the
    /// person's words, an agreement keeps the case's expectation, a skip teaches nothing.
    func derive(_ events: [RuntimeEvent], steward: StewardID) async throws -> [LearnedCheck] {
        enum Taught {
            case corrected(expected: JSONValue, note: String, by: String)
            case agreed(casebook: String, by: String)
            case skipped
        }
        var latest: [CaseID: Taught] = [:]
        var order: [CaseID] = []
        for event in events where event.draft.steward == steward {
            let caseID: CaseID
            let taught: Taught
            switch event.type {
            case EvalEventType.caseCorrected:
                let body = try EvalPayload.decode(CaseCorrectedPayload.self, event.payload)
                guard let expected = body.expected else { continue }
                caseID = body.caseID
                taught = .corrected(expected: expected, note: body.text, by: event.draft.actor.id)
            case ReviewEventType.reviewed:
                let body = try EvalPayload.decode(CaseReviewedPayload.self, event.payload)
                caseID = body.caseID
                taught =
                    body.verdict == .agreed
                    ? .agreed(casebook: body.casebook, by: event.draft.actor.id) : .skipped
            default: continue
            }
            if latest[caseID] == nil { order.append(caseID) }
            latest[caseID] = taught
        }
        let book = try CasebookBook(events)
        var expectations: [String: [CaseID: JSONValue]] = [:]
        var checks: [LearnedCheck] = []
        for caseID in order {
            switch latest[caseID] {
            case .corrected(let expected, let note, let by):
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                checks += Self.checks(
                    caseID, expected: expected, origin: .corrected, by: by,
                    text: text.isEmpty ? nil : text)
            case .agreed(let casebook, let by):
                if expectations[casebook] == nil {
                    let newest = book.versions.values
                        .filter { $0.steward == steward && $0.imported.name == casebook }
                        .max { $0.seq < $1.seq }
                    var map: [CaseID: JSONValue] = [:]
                    if let newest {
                        for item in try await casebooks.casebook(version: newest.imported.version)
                            .cases
                        { map[item.id] = item.expected }
                    }
                    expectations[casebook] = map
                }
                guard let expected = expectations[casebook]?[caseID] else { continue }
                checks += Self.checks(caseID, expected: expected, origin: .agreed, by: by)
            case .skipped, nil: continue
            }
        }
        return checks
    }

    /// The checks an expectation teaches: one per expected choice, or one per expected action
    /// target when it names no choice.
    static func checks(
        _ caseID: CaseID, expected: JSONValue, origin: LearnedCheck.Origin, by: String,
        text: String? = nil
    ) -> [LearnedCheck] {
        let choices = unique(expected.values(at: "decisions.choice"))
        let path = choices.isEmpty ? "actions.target" : "decisions.choice"
        let values = choices.isEmpty ? unique(expected.values(at: path)) : choices
        return values.map { value in
            let check = RubricCheck(kind: .equals, path: path, value: value)
            let said =
                choices.isEmpty
                ? "acts on \(ResultText.value(value))" : "chooses \(ResultText.value(value))"
            return LearnedCheck(
                id: "\(caseID.rawValue)/\(path)=\(ResultText.value(value))", caseID: caseID,
                text: text ?? "\(said.prefix(1).uppercased())\(said.dropFirst()) (agreed)",
                check: check, origin: origin, by: by)
        }
    }

    static func unique(_ values: [JSONValue]) -> [JSONValue] {
        var seen: [JSONValue] = []
        for value in values where !seen.contains(value) { seen.append(value) }
        return seen
    }
}
