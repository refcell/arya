import AryaCore

/// Ledger event types owned by the routine library.
public enum RoutineEventType {
    public static let proposed = "routine.proposed"
    public static let promoted = "routine.promoted"
    public static let retired = "routine.retired"
}

/// Payload of `routine.proposed`: a new routine or a new version of one. The content is the
/// blob named by `version`. The steward is the envelope's `steward`; who proposed it is the
/// envelope's `actor`, and `run` is set when a run proposed it.
public struct RoutineProposedPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var name: String
    public var version: String
    public var language: RoutineLanguage
    public var bytes: Int
    public var summary: String
    public var reason: String?
    public var run: RunID?

    public init(source: RoutineSource, reason: String? = nil, run: RunID? = nil) {
        self.v = 1
        self.name = source.name
        self.version = source.version
        self.language = source.language
        self.bytes = source.content.utf8.count
        self.summary = source.summary(reason: reason)
        self.reason = reason
        self.run = run
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case name
        case version
        case language
        case bytes
        case summary
        case reason
        case run
    }
}

/// Payload of `routine.promoted`: `version` becomes the live version of `name`. Written only
/// after the proposal's gate passed or a person overrode it; `proposal` links the decision.
public struct RoutinePromotedPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var name: String
    public var version: String
    public var proposal: ProposalID?

    public init(name: String, version: String, proposal: ProposalID? = nil) {
        self.v = 1
        self.name = name
        self.version = version
        self.proposal = proposal
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case name
        case version
        case proposal
    }
}

/// Payload of `routine.retired`: `name` has no live version afterwards. `version` is the live
/// version being retired, so a stale retirement is detectable.
public struct RoutineRetiredPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var name: String
    public var version: String
    public var reason: String?

    public init(name: String, version: String, reason: String? = nil) {
        self.v = 1
        self.name = name
        self.version = version
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case name
        case version
        case reason
    }
}
