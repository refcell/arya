import AryaCore
import AryaRuntime

/// Event type of a person's review of one case.
public enum ReviewEventType {
    /// `case.reviewed`: a person agreed with or skipped a case (corrections are
    /// `case.corrected`).
    public static let reviewed = "case.reviewed"
}

/// Payload of `case.reviewed` (actor: the person).
public struct CaseReviewedPayload: Hashable, Sendable, Codable {
    public enum Verdict: String, Hashable, Sendable, Codable {
        /// What the steward would have done is right (or matches what the person did).
        case agreed
        /// Left for later; it stays in the queue's count as reviewed but not agreed.
        case skipped
    }

    public var v: Int = 1
    public var casebook: String
    public var caseID: CaseID
    public var verdict: Verdict
    public var rehearsal: RehearsalID?

    public init(
        casebook: String, caseID: CaseID, verdict: Verdict, rehearsal: RehearsalID? = nil
    ) {
        self.casebook = casebook
        self.caseID = caseID
        self.verdict = verdict
        self.rehearsal = rehearsal
    }

    enum CodingKeys: String, CodingKey {
        case v, casebook, verdict, rehearsal
        case caseID = "case"
    }
}

/// Where one case stands in the review queue.
public enum ReviewStatus: String, Hashable, Sendable, Codable {
    case pending, agreed, corrected, skipped
}

/// One case to review: what the steward would have done next to what the person did.
public struct ReviewItem: Hashable, Sendable, Codable {
    public var caseID: String
    public var input: String
    /// In words; `Not rehearsed yet.` before the case was rehearsed.
    public var wouldHave: String
    public var personDid: String
    /// Whether the steward's answer matched; `nil` before it was rehearsed.
    public var matches: Bool?
    /// The difference in a line, or empty when it matches.
    public var difference: String
    /// Where the case came from, for example `history inbox.history item MSG-110 by person:sam`.
    public var source: String
    public var status: ReviewStatus
}

/// The review queue: a steward's newest casebook, case by case, pending cases first (those
/// where the steward disagreed with the person before those where it agreed).
public struct ReviewQueueView: Hashable, Sendable, Codable {
    public var steward: String
    public var casebook: String
    public var casebookVersion: String
    /// The live rehearsal the answers come from, if any.
    public var rehearsal: String?
    public var items: [ReviewItem]
    public var total: Int
    public var reviewed: Int
    public var agreed: Int
    public var corrected: Int
    public var skipped: Int
    /// Rehearsed cases where the steward matched what the person did.
    public var matching: Int
    /// One line, shown verbatim: `12 of 20 reviewed · 15 of 20 match what people did`.
    public var progressText: String
    /// The first pending case, or `nil` when every case is reviewed.
    public var next: ReviewItem?
}

/// Builds the review queue and records reviews.
public struct ReviewQueue: Sendable {
    public var sink: any EventSink
    public var casebooks: any CasebookSource

    public init(sink: any EventSink, casebooks: any CasebookSource) {
        self.sink = sink
        self.casebooks = casebooks
    }

    /// The queue on the steward's newest casebook; `nil` when it has none.
    public func view(steward: StewardID) async throws -> ReviewQueueView? {
        let events = try await sink.events(from: 1)
        guard
            let newest = try CasebookBook(events).versions.values
                .filter({ $0.steward == steward }).max(by: { $0.seq < $1.seq })
        else { return nil }
        let book = try await casebooks.casebook(version: newest.imported.version)
        let rehearsal = try Self.latestLiveRehearsal(events, steward: steward)
        var answers: [CaseID: SampleReport] = [:]
        if let rehearsal {
            let report = try await RehearsalReports(sink: sink, casebooks: casebooks)
                .report(rehearsal)
            for item in report.cases { answers[item.caseID] = item.samples.first }
        }
        let names = try CasebookBook(events).versions.mapValues(\.imported.name)
        let statuses = try Self.statuses(events, casebook: book.name, names: names)
        let items = book.cases.map { item -> ReviewItem in
            let answer = answers[item.id]
            return ReviewItem(
                caseID: item.id.rawValue, input: item.input.text,
                wouldHave: answer?.text ?? "Not rehearsed yet.",
                personDid: ResultText.describe(item.expected),
                matches: answer.map { $0.score.passed },
                difference: answer.map { $0.score.passed ? "" : $0.diffText } ?? "",
                source: item.source ?? "", status: statuses[item.id] ?? .pending)
        }
        return Self.layout(
            items, steward: steward, book: book, rehearsal: rehearsal?.rawValue)
    }

    /// Records that `person` agreed with or skipped a case of `casebook`.
    public func record(
        _ verdict: CaseReviewedPayload.Verdict, caseID: CaseID, casebook: Casebook,
        steward: StewardID, person: String, rehearsal: RehearsalID? = nil
    ) async throws {
        guard casebook.cases.contains(where: { $0.id == caseID }) else {
            throw EvalError.unknownCase(caseID)
        }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ReviewEventType.reviewed, steward: steward, run: nil,
                actor: .person(person),
                payload: try CanonicalJSON.jsonValue(
                    CaseReviewedPayload(
                        casebook: casebook.name, caseID: caseID, verdict: verdict,
                        rehearsal: rehearsal))))
    }

    static func layout(
        _ items: [ReviewItem], steward: StewardID, book: Casebook, rehearsal: String?
    ) -> ReviewQueueView {
        func rank(_ item: ReviewItem) -> Int {
            switch (item.status, item.matches) {
            case (.pending, false?): return 0
            case (.pending, nil): return 1
            case (.pending, true?): return 2
            default: return 3
            }
        }
        let ordered = items.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        let count = { (status: ReviewStatus) in items.filter { $0.status == status }.count }
        let reviewed = items.count - count(.pending)
        let matching = items.filter { $0.matches == true }.count
        var progress = "\(reviewed) of \(items.count) reviewed"
        if items.contains(where: { $0.matches != nil }) {
            progress += " · \(matching) of \(items.count) match what people did"
        }
        return ReviewQueueView(
            steward: steward.rawValue, casebook: book.name, casebookVersion: book.version,
            rehearsal: rehearsal, items: ordered, total: items.count, reviewed: reviewed,
            agreed: count(.agreed), corrected: count(.corrected), skipped: count(.skipped),
            matching: matching, progressText: progress,
            next: ordered.first { $0.status == .pending })
    }

    /// The newest finished live rehearsal (a charter version, no proposal or routine).
    static func latestLiveRehearsal(_ events: [RuntimeEvent], steward: StewardID) throws
        -> RehearsalID?
    {
        try RehearsalBook(events).records.values
            .filter {
                let request = $0.result.request
                return $0.finished && request.steward == steward && request.charterVersion > 0
                    && request.proposal == nil && request.routine == nil
            }
            .max { ($0.finishedSeq ?? 0) < ($1.finishedSeq ?? 0) }?.result.id
    }

    /// The latest review or correction of each case of a casebook name. Corrections name a
    /// casebook version; `names` maps versions to casebook names.
    static func statuses(
        _ events: [RuntimeEvent], casebook: String, names: [String: String]
    ) throws
        -> [CaseID: ReviewStatus]
    {
        var statuses: [CaseID: ReviewStatus] = [:]
        for event in events {
            switch event.type {
            case ReviewEventType.reviewed:
                let body = try EvalPayload.decode(CaseReviewedPayload.self, event.payload)
                guard body.casebook == casebook else { continue }
                statuses[body.caseID] = body.verdict == .agreed ? .agreed : .skipped
            case EvalEventType.caseCorrected:
                let body = try EvalPayload.decode(CaseCorrectedPayload.self, event.payload)
                guard (names[body.casebook] ?? body.casebook) == casebook else { continue }
                statuses[body.caseID] = .corrected
            default:
                continue
            }
        }
        return statuses
    }
}
