import AryaCore
import AryaRuntime

/// One rehearsal as projected from the ledger.
public struct RehearsalRecord: Hashable, Sendable {
    public var result: RehearsalResult
    public var finished: Bool
    /// `seq` of the `rehearsal.finished` event, when finished.
    public var finishedSeq: Int?
}

/// Folds `rehearsal.*` events into records and finds gate baselines.
public struct RehearsalBook: Sendable {
    public private(set) var records: [RehearsalID: RehearsalRecord] = [:]

    public init() {}

    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    /// Applies one event; events of other types are ignored.
    public mutating func apply(_ event: RuntimeEvent) throws {
        switch event.type {
        case EvalEventType.rehearsalStarted:
            guard let steward = event.draft.steward else { return }
            let body = try EvalPayload.decode(RehearsalStartedPayload.self, event.payload)
            let request = RehearsalRequest(
                steward: steward, charterVersion: body.charterVersion,
                casebookVersion: body.casebookVersion, samples: body.samples,
                proposal: body.proposal, routine: body.routine)
            records[body.rehearsal] = RehearsalRecord(
                result: RehearsalResult(id: body.rehearsal, request: request, outcomes: []),
                finished: false, finishedSeq: nil)
        case EvalEventType.rehearsalCaseScored:
            let body = try EvalPayload.decode(RehearsalCaseScoredPayload.self, event.payload)
            guard var record = records[body.rehearsal] else { return }
            let outcome = CaseOutcome(caseID: body.caseID, samples: body.scores, leak: body.leak)
            record.result = RehearsalResult(
                id: body.rehearsal, request: record.result.request,
                outcomes: record.result.outcomes + [outcome])
            records[body.rehearsal] = record
        case EvalEventType.rehearsalFinished:
            let body = try EvalPayload.decode(RehearsalFinishedPayload.self, event.payload)
            records[body.rehearsal]?.finished = true
            records[body.rehearsal]?.finishedSeq = event.seq
        default:
            return
        }
    }

    /// The latest finished rehearsal of a live charter version (no proposal, no candidate
    /// routine) on a casebook version that finished after `seq`, the steward's latest
    /// configuration change: the gate baseline (decision 0017).
    public func baseline(
        steward: StewardID, charterVersion: Int, casebookVersion: String, after seq: Int = 0
    ) -> RehearsalResult? {
        records.values
            .filter { record in
                let request = record.result.request
                return record.finished && (record.finishedSeq ?? 0) > seq
                    && request.proposal == nil && request.routine == nil
                    && request.steward == steward
                    && request.charterVersion == charterVersion
                    && request.casebookVersion == casebookVersion
            }
            .max { ($0.finishedSeq ?? 0) < ($1.finishedSeq ?? 0) }?
            .result
    }

    /// Finished rehearsals of a steward, newest first.
    public func finished(steward: StewardID) -> [RehearsalResult] {
        records.values
            .filter { $0.finished && $0.result.request.steward == steward }
            .sorted { ($0.finishedSeq ?? 0) > ($1.finishedSeq ?? 0) }
            .map(\.result)
    }
}

/// Converts payload structs to and from `JSONValue`.
enum EvalPayload {
    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try CanonicalJSON.decode(type, from: try CanonicalJSON.encode(value))
    }
}
