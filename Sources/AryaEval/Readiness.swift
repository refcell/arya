import AryaCore
import AryaRuntime

/// Ledger event types recorded by eval.
public enum EvalEventType {
    public static let casebookImported = "casebook.imported"
    public static let caseCorrected = "case.corrected"
    public static let rehearsalStarted = "rehearsal.started"
    public static let rehearsalCaseScored = "rehearsal.case.scored"
    public static let rehearsalFinished = "rehearsal.finished"
}

/// Payload of `steward.ready`: the charter version a person approved and the rehearsal they
/// reviewed, if any.
public struct StewardReadyPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var charterVersion: Int
    public var rehearsal: RehearsalID?
    public var casebook: String?
    public var meanScore: Double?

    enum CodingKeys: String, CodingKey {
        case v, charterVersion, rehearsal, casebook, meanScore
    }
}

/// Records that a person marked a steward ready for live triggers. Only people may do it.
public struct Readiness: Sendable {
    public var sink: any EventSink

    public init(sink: any EventSink) {
        self.sink = sink
    }

    @discardableResult
    public func markReady(
        steward: StewardID, charterVersion: Int, reviewed rehearsal: RehearsalResult?,
        person: String
    ) async throws -> RuntimeEvent {
        let payload = StewardReadyPayload(
            charterVersion: charterVersion, rehearsal: rehearsal?.id,
            casebook: rehearsal?.request.casebookVersion,
            meanScore: rehearsal.map(GateRule.mean))
        return try await sink.append(
            RuntimeEventDraft(
                type: StewardEventType.ready, steward: steward, actor: .person(person),
                payload: try CanonicalJSON.jsonValue(payload)))
    }
}
