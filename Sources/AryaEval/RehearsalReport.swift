import AryaCore
import AryaRuntime

/// One field where a result differs from what a case expects.
public struct FieldDiff: Hashable, Sendable, Codable {
    /// Where, from the result's root: `decisions[0].choice`.
    public var path: String
    /// `nil` (absent, unlike JSON `null`) when the case expects nothing there: an extra item.
    public var expected: JSONValue?
    /// `nil` when the result has nothing there.
    public var actual: JSONValue?

    public init(path: String, expected: JSONValue?, actual: JSONValue?) {
        self.path = path
        self.expected = expected
        self.actual = actual
    }
}

/// Compares a result with a case's `expected`. Only what the case states is compared: object
/// keys the case leaves out are ignored, while arrays compare item by item, including extra or
/// missing items. Pure and ordered by path.
public enum ResultDiff {
    public static func diff(expected: JSONValue, actual: JSONValue?) -> [FieldDiff] {
        var out: [FieldDiff] = []
        walk(expected, actual, "", &out)
        return out
    }

    private static func walk(
        _ expected: JSONValue?, _ actual: JSONValue?, _ path: String, _ out: inout [FieldDiff]
    ) {
        switch (expected, actual) {
        case (.object(let want)?, .object(let have)?):
            for (key, value) in want.sorted(by: { $0.key < $1.key }) {
                walk(value, have[key], path.isEmpty ? key : "\(path).\(key)", &out)
            }
        case (.array(let want)?, .array(let have)?):
            for index in 0..<max(want.count, have.count) {
                let wanted: JSONValue? = index < want.count ? want[index] : .none
                let had: JSONValue? = index < have.count ? have[index] : .none
                walk(wanted, had, "\(path)[\(index)]", &out)
            }
        default:
            if expected != actual {
                out.append(FieldDiff(path: path, expected: expected, actual: actual))
            }
        }
    }
}

/// One sample of one case: which run, what it produced, how it scored, and where it differs.
public struct SampleReport: Hashable, Sendable, Codable {
    public var run: RunID?
    /// `nil` when the run failed or the event predates recorded results.
    public var actual: JSONValue?
    public var score: CaseScore
    public var diff: [FieldDiff]
}

/// One case of a rehearsal, as the app's review screen shows it.
public struct CaseReport: Hashable, Sendable, Codable {
    public var caseID: CaseID
    public var input: String
    public var expected: JSONValue
    public var samples: [SampleReport]
    public var leak: Bool
    /// Every sample passed.
    public var passed: Bool
    /// Corrections a person recorded from this rehearsal for this case.
    public var corrections: [CaseCorrectedPayload]
}

/// A rehearsal's review model: per case expected versus actual, score notes, leak, and the
/// corrections applied (eval lane backlog).
public struct RehearsalReport: Hashable, Sendable, Codable {
    public var rehearsal: RehearsalID
    public var steward: StewardID
    public var charterVersion: Int
    public var casebook: String
    public var casebookVersion: String
    public var proposal: ProposalID?
    public var routine: RoutineCandidate?
    public var finished: Bool
    public var meanScore: Double
    public var passed: Int
    public var leaks: Int
    public var cases: [CaseReport]
}

/// Builds `RehearsalReport`s from the ledger and stored casebooks.
public struct RehearsalReports: Sendable {
    public var sink: any EventSink
    public var casebooks: any CasebookSource

    public init(sink: any EventSink, casebooks: any CasebookSource) {
        self.sink = sink
        self.casebooks = casebooks
    }

    public func report(_ id: RehearsalID) async throws -> RehearsalReport {
        let events = try await sink.events(from: 1)
        guard let record = try RehearsalBook(events).records[id] else {
            throw EvalError.unknownRehearsal(id)
        }
        let request = record.result.request
        let book = try await casebooks.casebook(version: request.casebookVersion)
        let scored = try Self.scored(events, id)
        let corrections = try Self.corrections(events, id)
        let cases = book.cases.map { item in
            Self.caseReport(item, scored[item.id], corrections[item.id] ?? [])
        }
        let outcomes = record.result.outcomes
        return RehearsalReport(
            rehearsal: id, steward: request.steward, charterVersion: request.charterVersion,
            casebook: book.name, casebookVersion: book.version, proposal: request.proposal,
            routine: request.routine, finished: record.finished,
            meanScore: GateRule.mean(record.result),
            passed: outcomes.filter(GateRule.alwaysPassed).count,
            leaks: outcomes.filter(\.leak).count, cases: cases)
    }

    /// The recorded result of a rehearsal.
    public func result(_ id: RehearsalID) async throws -> RehearsalResult {
        guard let record = try RehearsalBook(try await sink.events(from: 1)).records[id] else {
            throw EvalError.unknownRehearsal(id)
        }
        return record.result
    }

    static func caseReport(
        _ item: Case, _ scored: RehearsalCaseScoredPayload?, _ corrections: [CaseCorrectedPayload]
    ) -> CaseReport {
        let scores = scored?.scores ?? []
        let samples = scores.indices.map { index in
            let recorded: JSONValue? = scored?.results?[safe: index].flatMap { $0 }
            let actual: JSONValue? = recorded == .null ? .none : recorded
            return SampleReport(
                run: scored?.runs[safe: index] ?? nil, actual: actual, score: scores[index],
                diff: actual.map { ResultDiff.diff(expected: item.expected, actual: $0) } ?? [])
        }
        return CaseReport(
            caseID: item.id, input: item.input.text, expected: item.expected, samples: samples,
            leak: scored?.leak ?? false, passed: !scores.isEmpty && scores.allSatisfy(\.passed),
            corrections: corrections)
    }

    static func scored(
        _ events: [RuntimeEvent], _ id: RehearsalID
    ) throws -> [CaseID: RehearsalCaseScoredPayload] {
        var out: [CaseID: RehearsalCaseScoredPayload] = [:]
        for event in events where event.type == EvalEventType.rehearsalCaseScored {
            let payload = try EvalPayload.decode(RehearsalCaseScoredPayload.self, event.payload)
            if payload.rehearsal == id { out[payload.caseID] = payload }
        }
        return out
    }

    static func corrections(
        _ events: [RuntimeEvent], _ id: RehearsalID
    ) throws -> [CaseID: [CaseCorrectedPayload]] {
        var out: [CaseID: [CaseCorrectedPayload]] = [:]
        for event in events where event.type == EvalEventType.caseCorrected {
            let payload = try EvalPayload.decode(CaseCorrectedPayload.self, event.payload)
            if payload.rehearsal == id { out[payload.caseID, default: []].append(payload) }
        }
        return out
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
