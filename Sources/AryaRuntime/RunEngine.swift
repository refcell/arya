import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import Foundation

// The run loop (ARCHITECTURE.md "Runs"): a trigger becomes `run.started`, a fresh adapter
// process streams into `run.adapter.event`, `run/result` becomes `run.decision` and disposed
// actions, and `run.finished` or `run.failed` closes the run. Every message in both directions
// is recorded, so a run can be replayed from the ledger alone.

/// Ledger event types for runs.
public enum RunEventType {
    /// A run began; carries everything it will see.
    public static let started = EventType.runStarted.rawValue
    /// One JSON-RPC line between arya and the adapter.
    public static let adapterEvent = EventType.runAdapterEvent.rawValue
    /// One decision from `run/result`.
    public static let decision = EventType.runDecision.rawValue
    /// The run ended normally.
    public static let finished = EventType.runFinished.rawValue
    /// The run failed.
    public static let failed = EventType.runFailed.rawValue
}

/// Whether a run may touch the world.
public enum RunMode: Sendable, Hashable {
    /// Actions go through policy, approval, and the executor.
    case live
    /// A rehearsal of a case (decision 0015): dispositions are recorded, nothing executes, and
    /// a tool call with no answer in `context` marks the run as leaking.
    case rehearsal(CaseContext)
}

/// A proposed routine version a rehearsal runs with.
public struct CandidateRoutine: Sendable, Hashable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
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
    /// The rehearsal, case, and 1-based sample a rehearsal run belongs to, if any.
    public var rehearsal: RehearsalTag?
    /// A routine version to run in place of the live version of its name (or added, for a new
    /// name): a routine proposal under rehearsal.
    public var routine: CandidateRoutine?
    /// Whether setbacks of this run start a re-plan run (decision 0046); replay turns it off.
    public var replanning = true
    /// For a crew child: the adapter, effort, and limits it runs with instead of the charter's.
    public var crew: CrewBudget?
    /// The run id to use instead of a fresh one (a crew child's id is recorded on
    /// `run.delegated` before it starts).
    var id: RunID?
    /// Whether a live top-level run's delegations become a crew (default `.run`). A replay
    /// skips it and replays each recorded child and join run on its own.
    public var crewPolicy: CrewPolicy = .run
    /// For a replay: each in-run delegation as recorded, by delegation id (decision 0053).
    public var delegations: [String: RecordedDelegation] = [:]

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

    /// Creates a request.
    public init(
        steward: StewardID, input: RunInput, mode: RunMode, actor: RuntimeActor,
        parent: RunID?, charter: Charter?, rehearsal: RehearsalTag?
    ) {
        self.init(
            steward: steward, input: input, mode: mode, actor: actor, parent: parent,
            charter: charter)
        self.rehearsal = rehearsal
    }

    /// A manual live run started by the local user.
    public static func manual(_ steward: StewardID, text: String) -> RunRequest {
        RunRequest(steward: steward, input: .init(kind: .manual, text: text))
    }
}

/// Whether `RunEngine.run` fans a live top-level run's delegations out into a crew.
public enum CrewPolicy: Sendable, Hashable {
    /// Run the crew (children, then the join).
    case run
    /// Return after the run itself; the caller handles any crew.
    case skip
}

/// Which rehearsal, case, and sample a run belongs to.
public struct RehearsalTag: Sendable, Hashable {
    /// The rehearsal.
    public var rehearsal: RehearsalID
    /// The case.
    public var caseID: CaseID
    /// 1-based sample number.
    public var sample: Int

    /// Creates a tag.
    public init(rehearsal: RehearsalID, caseID: CaseID, sample: Int) {
        self.rehearsal = rehearsal
        self.caseID = caseID
        self.sample = sample
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
    /// The crew this run delegated to, if any.
    public var crew: CrewOutcome?
    /// The re-plan run its failed actions started (at most one; it may have its own).
    public var replans: [RunOutcome] = []
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
    let secondsUnit: Duration
    let proxy: BindingProxyLaunch?
    /// Confine binding servers (through the proxies) to the run's workdir (decision 0040).
    let sandbox: Bool

    /// Creates a run engine. `workdir` returns (and may create) the scratch directory of a run.
    /// `questionPoll` is how often a `host/ask` question checks the ledger for an answer.
    /// `leases` must be shared with `RunRecovery` (file leases across processes).
    /// `secondsUnit` is how long one second of `limits.timeoutSeconds` lasts (tests shrink it).
    /// `proxy`, when set, gives each run one binding-proxy tool server per MCP binding.
    /// `sandbox` confines those servers to the run's workdir when `sandbox-exec` works, and
    /// records the sandbox on `run.started`.
    public init(
        sink: any EventSink, ambient: Ambient, adapters: any AdapterFactory,
        dispatcher: ActionDispatcher, approvals: ApprovalQueue,
        workdir: @escaping @Sendable (RunID) throws -> String,
        questionPoll: Duration = .milliseconds(250), leases: any RunLeases = MemoryRunLeases(),
        secondsUnit: Duration = .seconds(1), proxy: BindingProxyLaunch? = nil,
        sandbox: Bool = false
    ) {
        self.sandbox = sandbox
        self.secondsUnit = secondsUnit
        self.proxy = proxy
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
        var charter = request.charter ?? steward.charter
        if let crew = request.crew { charter = crew.applied(to: charter) }
        let version = request.charter == nil ? steward.version : 0
        let run = request.id ?? ambient.newID(RunID.self)
        var outcome = try await drive(run, request, charter, version)
        if request.fansOut, let delegations = outcome.result?.delegations, !delegations.isEmpty {
            outcome.crew = try await runCrew(
                delegations, parent: run, request: request, charter: charter)
        }
        if let replan = try await replanAfterFailures(outcome, request) {
            outcome.replans = [replan]
        }
        return outcome
    }

    private func drive(_ run: RunID, _ request: RunRequest, _ charter: Charter, _ version: Int)
        async throws -> RunOutcome
    {
        let lease = try leases.acquire(run)
        defer { lease.release() }
        let events = try await sink.events(from: 1)
        let context = try MemoryView(events).context(
            steward: request.steward, input: request.input.text,
            caseID: request.rehearsal?.caseID, candidate: request.routine)
        // A rehearsal shows the plan its case recorded, never the steward's live plan, so the
        // same case gets the same instructions however the live plan has moved since.
        let plan: [PlanItem]
        if case .rehearsal(let context) = request.mode {
            plan = context.plan.compactMap {
                try? CanonicalJSON.decode(PlanItem.self, from: try CanonicalJSON.encode($0))
            }
        } else {
            plan = try PlanBook(events).plans[request.steward] ?? []
        }
        var inputs = InstructionInputs(charter: charter, context: context, plan: plan)
        // A rehearsal sees no live results, so a case composes the same way every time.
        if case .live = request.mode {
            inputs.effects = try Effectiveness.of(request.steward, in: events)
        }
        let instructions = InstructionComposer.compose(inputs)
        try await recordStart(run, request, charter, version, instructions, context)
        let driver = RunDriver(
            loop: self, request: request, charter: charter, run: run, instructions: instructions,
            routines: context.routineVersions)
        return try await driver.drive()
    }

    /// What `run.started.sandbox` records, or nil (not `.null`) when unsandboxed.
    private func sandboxRecord(_ run: RunID, _ charter: Charter) throws -> JSONValue? {
        guard sandboxed else { return Optional<JSONValue>.none }
        return Sandbox.record(workdir: try workdir(run), charter: charter)
    }

    /// True when this engine's runs are sandboxed.
    var sandboxed: Bool { sandbox && Sandbox.available }

    private func recordStart(
        _ run: RunID, _ request: RunRequest, _ charter: Charter, _ version: Int,
        _ instructions: String, _ context: RunMemoryContext
    ) async throws {
        let input = request.input
        let payload = RunStarted(
            input: RunInputRecord(
                kind: RunTriggerKind(rawValue: input.kind.rawValue) ?? .manual, text: input.text,
                attachments: input.attachments.isEmpty ? nil : input.attachments),
            charterVersion: version, routines: context.routineVersions,
            memory: context.snapshotJSON, adapter: charter.adapter, effort: charter.effort,
            instructions: instructions, limits: charter.limits, parent: request.parent,
            rehearsal: request.rehearsal?.rehearsal, caseID: request.rehearsal?.caseID,
            sample: request.rehearsal?.sample,
            sandbox: try sandboxRecord(run, charter))
        _ = try await sink.append(
            RuntimeEventDraft(
                type: RunEventType.started, steward: request.steward, run: run,
                actor: request.actor, payload: try Payload.encode(payload)))
    }
}
