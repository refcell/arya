/// One recorded or re-derived ledger event, reduced to what replay compares.
public struct ReplayEvent: Hashable, Sendable, Codable {
    public var seq: Int
    public var type: String
    public var payload: EvalValue

    public init(seq: Int, type: String, payload: EvalValue) {
        self.seq = seq
        self.type = type
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case seq, type, payload
    }
}

/// The first point where a replayed run differs from its recording.
public struct Divergence: Hashable, Sendable, Codable {
    /// Position among the run's derived events, starting at 0.
    public var index: Int
    /// Dotted path of the differing field (`payload.choice`), or `event` for a missing event.
    public var path: String
    public var recorded: ReplayEvent?
    public var replayed: ReplayEvent?

    public init(index: Int, path: String, recorded: ReplayEvent?, replayed: ReplayEvent?) {
        self.index = index
        self.path = path
        self.recorded = recorded
        self.replayed = replayed
    }

    enum CodingKeys: String, CodingKey {
        case index, path, recorded, replayed
    }
}

/// The outcome of replaying one run. Zero divergence is the pass condition.
public struct ReplayReport: Hashable, Sendable, Codable {
    public var run: String
    public var comparedEvents: Int
    public var divergence: Divergence?

    public var passed: Bool { divergence == nil }

    public init(run: String, comparedEvents: Int, divergence: Divergence?) {
        self.run = run
        self.comparedEvents = comparedEvents
        self.divergence = divergence
    }

    enum CodingKeys: String, CodingKey {
        case run, comparedEvents, divergence
    }
}

/// Re-runs a recorded run against its recorded inputs and compares the derived events.
public protocol Replayer: Sendable {
    func replay(run: String) async throws -> ReplayReport
}

/// Placeholder until the runtime can be driven by a `ReplayAdapter`.
public struct StubReplayer: Replayer {
    public init() {}

    public func replay(run: String) async throws -> ReplayReport {
        throw EvalError.notImplemented("replay")
    }
}
