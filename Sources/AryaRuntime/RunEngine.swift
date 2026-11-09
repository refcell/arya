import AryaAdapters
import AryaCore
import Foundation

// The run loop (ARCHITECTURE.md "Runs"): a trigger becomes `run.started`, a fresh adapter
// process streams into `run.adapter.event`, `run/result` becomes `run.decision` and disposed
// actions, and `run.finished` or `run.failed` closes the run. Every message in both directions
// is recorded, so a run can be replayed from the ledger alone.

/// Ledger event types for runs.
public enum RunEventType {
    /// A run began; carries everything it will see.
    public static let started = "run.started"
    /// One JSON-RPC line between arya and the adapter.
    public static let adapterEvent = "run.adapter.event"
    /// One decision from `run/result`.
    public static let decision = "run.decision"
    /// The run ended normally.
    public static let finished = "run.finished"
    /// The run failed.
    public static let failed = "run.failed"
}

/// Whether a run may touch the world.
public enum RunMode: Sendable, Hashable {
    /// Actions go through policy, approval, and the executor.
    case live
    /// A rehearsal of a case (decision 0015): dispositions are recorded, nothing executes, and
    /// a tool call with no answer in `context` marks the run as leaking.
    case rehearsal(CaseContext)
}

/// What to run.
public struct RunRequest: Sendable, Hashable {
    /// The steward.
    public var steward: StewardID
    /// Trigger kind and input text.
    public var input: RunInput
    /// Live or rehearsal.
    public var mode: RunMode
    /// Who started it: the local user for manual runs, `system` for triggers and rehearsals.
    public var actor: RuntimeActor
    /// Parent run, for crew children.
    public var parent: RunID?
    /// A charter to run instead of the live one (a proposal under rehearsal), if any.
    public var charter: Charter?

    /// Creates a request.
    public init(
        steward: StewardID, input: RunInput, mode: RunMode = .live,
        actor: RuntimeActor = .localUser, parent: RunID? = nil, charter: Charter? = nil
    ) {
        self.steward = steward
        self.input = input
        self.mode = mode
        self.actor = actor
        self.parent = parent
        self.charter = charter
    }

    /// A manual live run started by the local user.
    public static func manual(_ steward: StewardID, text: String) -> RunRequest {
        RunRequest(steward: steward, input: .init(kind: .manual, text: text))
    }
}

/// How a run ended.
public struct RunOutcome: Sendable, Hashable {
    /// The run id.
    public var run: RunID
    /// Final phase: `finished` or `failed`.
    public var phase: RunPhase
    /// The decoded result, when one arrived and decoded.
    public var result: RunResult?
    /// Disposition of each proposed action, in result order.
    public var disposals: [ActionDisposal]
    /// True when a rehearsal tool call had no recorded answer.
    public var leak: Bool
}

/// Makes a fresh adapter for each run (one process per run, PROTOCOL.md).
public protocol AdapterFactory: Sendable {
    /// An adapter for `charter.adapter`, not yet initialized.
    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter
}

/// Why a run could not start.
public enum RunError: Error, Equatable, Sendable {
    /// The steward is retired.
    case stewardRetired(StewardID)
}

/// Starts runs and drives them to the end.
public struct RunEngine: Sendable {
    let sink: any EventSink
    let ambient: Ambient
    let adapters: any AdapterFactory
    let dispatcher: ActionDispatcher
    let approvals: ApprovalQueue
    let workdir: @Sendable (RunID) throws -> String
    let questionPoll: Duration
    let leases: any RunLeases

    /// Creates a run engine. `workdir` returns (and may create) the scratch directory of a run.
    /// `questionPoll` is how often a `host/ask` question checks the ledger for an answer.
    /// `leases` must be shared with `RunRecovery` (file leases across processes).
    public init(
        sink: any EventSink, ambient: Ambient, adapters: any AdapterFactory,
        dispatcher: ActionDispatcher, approvals: ApprovalQueue,
        workdir: @escaping @Sendable (RunID) throws -> String,
        questionPoll: Duration = .milliseconds(250), leases: any RunLeases = MemoryRunLeases()
    ) {
        self.leases = leases
        self.sink = sink
        self.ambient = ambient
        self.adapters = adapters
        self.dispatcher = dispatcher
        self.approvals = approvals
        self.workdir = workdir
        self.questionPoll = questionPoll
    }

    /// Runs `request` to completion and returns how it ended. Adapter failures end the run
    /// with `run.failed`; only ledger write errors and unknown stewards throw.
    public func run(_ request: RunRequest) async throws -> RunOutcome {
        let steward = try await StewardLifecycle(sink: sink).book().records[request.steward]
        guard let steward else { throw StewardError.notFound(request.steward) }
        guard steward.status != .retired else { throw RunError.stewardRetired(steward.id) }
        let charter = request.charter ?? steward.charter
        let version = request.charter == nil ? steward.version : 0
        let run = ambient.newID(RunID.self)
        let lease = try leases.acquire(run)
        defer { lease.release() }
        let instructions = InstructionComposer.compose(InstructionInputs(charter: charter))
        try await recordStart(run, request, charter, version, instructions)
        let driver = RunDriver(
            loop: self, request: request, charter: charter, run: run, instructions: instructions)
        return try await driver.drive()
    }

    private func recordStart(
        _ run: RunID, _ request: RunRequest, _ charter: Charter, _ version: Int,
        _ instructions: String
    ) async throws {
        let payload = RunStartedPayload(
            trigger: request.input.kind.rawValue, input: request.input, parent: request.parent,
            charterVersion: version, adapter: charter.adapter, effort: charter.effort.rawValue,
            instructions: instructions, memory: [], routines: [],
            rehearsal: request.mode != .live)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: RunEventType.started, steward: request.steward, run: run,
                actor: request.actor, payload: try Payload.encode(payload)))
    }
}

struct RunStartedPayload: Codable, Hashable {
    var trigger: String
    var input: RunInput
    var parent: RunID?
    /// The live charter version, or 0 for a candidate charter under rehearsal.
    var charterVersion: Int
    var adapter: String
    var effort: String
    var instructions: String
    /// Memory note ids in the snapshot (filled once memory retrieval is wired).
    var memory: [String]
    /// Live routine versions (filled once routines are wired).
    var routines: [String]
    var rehearsal: Bool

    enum CodingKeys: String, CodingKey {
        case trigger, input, parent, charterVersion, adapter, effort, instructions, memory
        case routines, rehearsal
    }
}

struct RunEndPayload: Codable, Hashable {
    var status: String?
    var reason: String?
    var detail: String?
    var summary: String?
    var costMicros: Int64
    var decisions: Int
    var actions: Int
    var leak: Bool

    enum CodingKeys: String, CodingKey {
        case status, reason, detail, summary, costMicros, decisions, actions, leak
    }
}
