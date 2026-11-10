import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
import Foundation

/// Replays a recorded run (ARCHITECTURE.md, "Replay"). It seeds a scratch sink with every
/// event before the run, drives a real `RunEngine` whose adapter is a `ReplayAdapter` over the
/// run's `run.adapter.event` records and whose executor answers from the recorded
/// `action.executed`/`action.failed` output, then compares the derived events.
///
/// The engine's ambient serves the recorded run id first. Until `env.read` is recorded, other
/// engine readings (approval ids, clock readings) come from a fallback, so both event lists
/// are canonicalized before comparison: prefixed ids and timestamps are renamed in order of
/// first appearance (`<id:1>`, `<time:1>`). A divergence in which events happen, their types,
/// or any other field is still reported.
public struct RunReplayer: Replayer {
    public var sink: any EventSink
    public var casebooks: (any CasebookSource)?
    /// Test hook: changes the state the replay starts from, standing in for a runtime bug that
    /// reads something the ledger did not record.
    var drift: (@Sendable ([RuntimeEvent]) -> [RuntimeEvent])?

    public init(sink: any EventSink, casebooks: (any CasebookSource)? = nil) {
        self.sink = sink
        self.casebooks = casebooks
    }

    /// Replays `run` and, when it delegated, each recorded child run and then its join run, in
    /// ledger order. The run itself replays without fanning out; the join replays from its
    /// recorded input, which carries the recorded child results.
    public func replay(run: RunID) async throws -> ReplayReport {
        let events = try await sink.events(from: 1)
        var report = try await replayOne(run, events)
        let members = try Self.crewMembers(of: run, in: events)
        if !members.isEmpty {
            var crew: [ReplayReport] = []
            for member in members { crew.append(try await replayOne(member, events)) }
            report.crew = crew
        }
        return report
    }

    func replayOne(_ run: RunID, _ events: [RuntimeEvent]) async throws -> ReplayReport {
        let recording = try RunRecording(run: run, events: events)
        var request = try await recording.request(casebooks: casebooks)
        request.crewPolicy = .skip
        request.delegations = recording.delegations
        request.crew = try Self.budget(of: run, in: events)
        let replayed = try await drive(recording, request)
        return Self.compare(run: run, recorded: recording.runEvents, replayed: replayed)
    }

    /// The budget a crew child ran with, from the parent's `run.delegated` naming it.
    static func budget(of run: RunID, in events: [RuntimeEvent]) throws -> CrewBudget? {
        for event in events where event.type == RunDelegated.type.rawValue {
            let body = try EvalPayload.decode(RunDelegated.self, event.payload)
            if body.child == run {
                return CrewBudget(adapter: body.adapter, effort: body.effort, limits: body.limits)
            }
        }
        return nil
    }

    /// The child and join runs whose parent is `run`, in the order they started.
    static func crewMembers(of run: RunID, in events: [RuntimeEvent]) throws -> [RunID] {
        try events.filter { $0.type == RunEventType.started }.compactMap { event in
            let body = try EvalPayload.decode(RunStarted.self, event.payload)
            return body.parent == run ? event.draft.run : nil
        }
    }

    /// Runs the engine on the recorded inputs and returns the events it appended for the run.
    func drive(_ recording: RunRecording, _ request: RunRequest) async throws -> [RuntimeEvent] {
        let scratch = ReplaySink(
            prefix: drift?(recording.prefix) ?? recording.prefix,
            envelopes: recording.runEvents.map { ($0.id, $0.at) })
        let workdir = recording.workdir
        let ambient = Ambient.recorded([.id(recording.run.rawValue)])
        let approvals = ApprovalQueue(sink: scratch, ambient: ambient)
        let engine = RunEngine(
            sink: scratch, ambient: ambient,
            adapters: ReplayAdapters(records: recording.wireRecords),
            dispatcher: ActionDispatcher(
                sink: scratch, approvals: approvals,
                executor: RecordedExecutor(outcomes: recording.executions)),
            approvals: approvals, workdir: { workdir ?? "replay/\($0.rawValue)" },
            sandbox: recording.started.payload["sandbox"].map { $0 != .null } ?? false)
        let outcome = try await engine.run(request)
        return await scratch.appended().filter { $0.draft.run == outcome.run }
    }

    /// Compares derived events after canonicalizing ids and times.
    public static func compare(
        run: RunID, recorded: [RuntimeEvent], replayed: [RuntimeEvent]
    ) -> ReplayReport {
        let old = Canonicalizer.events(recorded.filter(isDerived))
        let new = Canonicalizer.events(replayed.filter(isDerived))
        return ReplayReport(
            run: run, comparedEvents: max(old.count, new.count),
            divergence: DivergenceFinder.firstDivergence(recorded: old, replayed: new))
    }

    /// Recorded inputs are not compared: adapter messages (the `ReplayAdapter` already fails on
    /// any host line that differs), ambient readings, and everything a person did.
    static func isDerived(_ event: RuntimeEvent) -> Bool {
        event.type != RunEventType.adapterEvent && event.type != EventType.envRead.rawValue
            && event.draft.actor.kind != "human"
    }
}

/// The recorded slice of one run.
struct RunRecording: Sendable {
    let run: RunID
    let started: RuntimeEvent
    let prefix: [RuntimeEvent]
    let runEvents: [RuntimeEvent]

    init(run: RunID, events: [RuntimeEvent]) throws {
        guard
            let started = events.first(where: {
                $0.draft.run == run && $0.type == RunEventType.started
            })
        else { throw EvalError.unknownRun(run) }
        self.run = run
        self.started = started
        prefix = events.filter { $0.seq < started.seq }
        var slice: [RuntimeEvent] = []
        for event in events where event.seq >= started.seq && event.draft.run == run {
            slice.append(event)
            if event.type == RunEventType.finished || event.type == RunEventType.failed { break }
        }
        runEvents = slice
    }

    /// The `workdir` the recorded `run/start` carried, so the replayed host line matches.
    var workdir: String? {
        runEvents.lazy.filter { $0.type == RunEventType.adapterEvent }
            .compactMap { event -> String? in
                guard event.payload["direction"] == "sent",
                    event.payload["message"]?["method"] == .string(RPCMethod.runStart)
                else { return nil }
                return event.payload["message"]?["params"]?["workdir"]?.stringValue
            }
            .first
    }

    var wireRecords: [WireRecord] {
        runEvents.filter { $0.type == RunEventType.adapterEvent }
            .compactMap { WireRecord(ledgerPayload: $0.payload) }
    }

    /// Each in-run delegation (`host/delegate`) as recorded, by delegation id: the parent's
    /// `run.delegated` and the answer arya sent (runtime decision 0052).
    var delegations: [String: RecordedDelegation] {
        var asked: [RPCID: String] = [:]
        var answers: [String: HostDelegateResult] = [:]
        for record in wireRecords {
            switch record.message {
            case .request(let request)? where request.method == RPCMethod.hostDelegate:
                asked[request.id] = request.params?["id"]?.stringValue
            case .response(let response)?:
                guard let id = asked[response.id], case .success(let value) = response.outcome,
                    let answer = try? EvalPayload.decode(HostDelegateResult.self, value)
                else { continue }
                answers[id] = answer
            default:
                continue
            }
        }
        var recorded: [String: RecordedDelegation] = [:]
        for (id, answer) in answers {
            let delegated = runEvents.first {
                $0.type == RunDelegated.type.rawValue && $0.payload["delegation"]?.stringValue == id
            }
            recorded[id] = RecordedDelegation(
                delegated: delegated.flatMap {
                    try? EvalPayload.decode(RunDelegated.self, $0.payload)
                },
                answer: answer)
        }
        return recorded
    }

    var executions: [ExecutionOutcome] {
        runEvents.compactMap { event in
            switch event.type {
            case ActionEventType.executed:
                let output = event.payload["output"] ?? .null
                return event.payload["dryRun"] == true
                    ? .drafted(output: output) : .succeeded(output: output)
            case ActionEventType.failed:
                let error = event.payload["error"]?.stringValue ?? ""
                return .failed(error: error, output: event.payload["output"])
            default:
                return nil
            }
        }
    }

    /// The request that started the run, rebuilt from `run.started`.
    func request(casebooks: (any CasebookSource)?) async throws -> RunRequest {
        let body = try EvalPayload.decode(RunStarted.self, started.payload)
        let input = RunInput(
            kind: RunInputKind(rawValue: body.input.kind.rawValue) ?? .manual,
            text: body.input.text, attachments: body.input.attachments ?? [])
        guard let steward = started.draft.steward else { throw EvalError.unknownRun(run) }
        var request = RunRequest(
            steward: steward, input: input, actor: started.draft.actor, parent: body.parent)
        request.replanning = false  // a re-plan is its own recorded run
        if body.parent != nil, input.kind != .join, input.kind != .replan {
            // A crew child ran with the adapter, effort, and limits recorded at its start.
            request.crew = CrewBudget(
                adapter: body.adapter, effort: body.effort, limits: body.limits)
        }
        if let rehearsal = body.rehearsal, let caseID = body.caseID {
            try await rehearse(&request, rehearsal, caseID, body, casebooks)
        }
        return request
    }

    /// Rehearsal runs replay in rehearsal mode with the case's recorded context and, for a
    /// candidate (charter version 0), the proposal's charter.
    private func rehearse(
        _ request: inout RunRequest, _ rehearsal: RehearsalID, _ caseID: CaseID,
        _ body: RunStarted, _ casebooks: (any CasebookSource)?
    ) async throws {
        let all = prefix + runEvents
        guard let record = try RehearsalBook(all).records[rehearsal], let casebooks else {
            throw EvalError.unknownRehearsal(rehearsal)
        }
        let book = try await casebooks.casebook(version: record.result.request.casebookVersion)
        guard let item = book.cases.first(where: { $0.id == caseID }) else {
            throw EvalError.unknownCase(caseID)
        }
        request.mode = .rehearsal(item.context)
        request.rehearsal = RehearsalTag(
            rehearsal: rehearsal, caseID: caseID, sample: body.sample ?? 1)
        request.routine = record.result.request.routine.map {
            CandidateRoutine(name: $0.name, version: $0.version)
        }
        if body.charterVersion == 0, let proposal = record.result.request.proposal {
            request.charter = try ProposalBook(all).records[proposal]?.charter
        }
    }
}

/// A sink preloaded with the events before a replayed run. Appends continue its `seq` and take
/// the recorded run's envelope ids and times in order, then a fixed fallback.
actor ReplaySink: EventSink {
    private var stored: [RuntimeEvent]
    private var envelopes: ArraySlice<(EventID, Timestamp)>
    private let firstAppended: Int
    private let ambient = Ambient.fixed()

    init(prefix: [RuntimeEvent], envelopes: [(EventID, Timestamp)]) {
        stored = prefix
        self.envelopes = envelopes[...]
        firstAppended = (prefix.last?.seq ?? 0) + 1
    }

    func append(_ draft: RuntimeEventDraft) async throws -> RuntimeEvent {
        let (id, at) = envelopes.popFirst() ?? (ambient.newID(EventID.self), ambient.now())
        let event = RuntimeEvent(
            seq: (stored.last?.seq ?? 0) + 1, id: id, at: at, draft: draft)
        stored.append(event)
        return event
    }

    func events(from seq: Int) async throws -> [RuntimeEvent] {
        stored.filter { $0.seq >= seq }
    }

    func appended() -> [RuntimeEvent] {
        stored.filter { $0.seq >= firstAppended }
    }
}

/// Hands every run the same recorded conversation.
struct ReplayAdapters: AdapterFactory {
    let records: [WireRecord]

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        GuardedAdapter(ReplayAdapter(records: records))
    }
}

/// Forwards to a recorded adapter and, once any call fails (a replay divergence), publishes an
/// exit so the run fails and the divergence is reported instead of waiting for updates that
/// will never come.
actor GuardedAdapter: Adapter {
    nonisolated let updates: AsyncStream<AdapterUpdate>
    private let continuation: AsyncStream<AdapterUpdate>.Continuation
    private let inner: any Adapter
    private var forwarding: Task<Void, Never>?

    init(_ inner: any Adapter) {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.inner = inner
        let continuation = continuation
        forwarding = Task {
            for await update in inner.updates { continuation.yield(update) }
            continuation.finish()
        }
    }

    private func guarded<T: Sendable>(
        _ body: () async throws(AdapterError) -> T
    ) async throws(AdapterError) -> T {
        do {
            return try await body()
        } catch {
            forwarding?.cancel()
            continuation.yield(.exited(.exited(70)))
            continuation.finish()
            throw error
        }
    }

    func initialize(_ params: InitializeParams) async throws(AdapterError) -> InitializeResult {
        try await guarded { () async throws(AdapterError) in try await inner.initialize(params) }
    }

    func start(_ params: RunStartParams) async throws(AdapterError) -> RunStartResult {
        try await guarded { () async throws(AdapterError) in try await inner.start(params) }
    }

    func send(_ params: RunSendParams) async throws(AdapterError) {
        try await guarded { () async throws(AdapterError) in try await inner.send(params) }
    }

    func stop(_ params: RunStopParams) async throws(AdapterError) {
        try await guarded { () async throws(AdapterError) in try await inner.stop(params) }
    }

    func transcript(_ params: SessionParams) async throws(AdapterError) -> TranscriptResult {
        try await guarded { () async throws(AdapterError) in try await inner.transcript(params) }
    }

    func cost(_ params: SessionParams) async throws(AdapterError) -> CostResult {
        try await guarded { () async throws(AdapterError) in try await inner.cost(params) }
    }

    func shutdown() async throws(AdapterError) {
        try await guarded { () async throws(AdapterError) in try await inner.shutdown() }
    }

    func answer(_ id: RPCID, _ result: HostAskResult) async throws(AdapterError) {
        try await guarded { () async throws(AdapterError) in try await inner.answer(id, result) }
    }

    func answerDelegation(_ id: RPCID, _ result: HostDelegateResult) async throws(AdapterError) {
        try await guarded { () async throws(AdapterError) in
            try await inner.answerDelegation(id, result)
        }
    }
}

/// Answers each execution with the next recorded outcome; never touches a system. Past the
/// recording it fails the action, which surfaces as a divergence.
actor RecordedExecutor: ActionExecutor {
    private var outcomes: [ExecutionOutcome]

    init(outcomes: [ExecutionOutcome]) {
        self.outcomes = outcomes
    }

    func execute(_ request: ExecutionRequest) async -> ExecutionOutcome {
        guard !outcomes.isEmpty else {
            return .failed(error: "replay: no recorded execution", output: nil)
        }
        return outcomes.removeFirst()
    }
}

/// Renames ids and timestamps by first appearance so a replay can be compared with its
/// recording while ambient readings other than the run id are not yet recorded. Durations
/// measured by the clock (a step's `millis`) are dropped: a replay runs at its own speed.
enum Canonicalizer {
    /// Payload fields that time a step rather than describe it, by event type.
    static let durations: [String: Set<String>] = ["run.step.finished": ["millis"]]

    static func events(_ events: [RuntimeEvent]) -> [ReplayEvent] {
        var names: [String: String] = [:]
        return events.enumerated().map { index, event in
            var payload = event.payload
            if let drop = durations[event.type], case .object(var fields) = payload {
                for key in drop { fields[key] = nil }
                payload = .object(fields)
            }
            let envelope: JSONValue = [
                "actor": .string("\(event.draft.actor.kind):\(event.draft.actor.id)"),
                "payload": payload,
            ]
            return ReplayEvent(
                seq: index + 1, type: event.type, payload: rename(envelope, &names))
        }
    }

    static func rename(_ value: JSONValue, _ names: inout [String: String]) -> JSONValue {
        switch value {
        case .string(let text):
            guard let kind = kind(of: text) else { return value }
            if let name = names[text] { return .string(name) }
            let count = names.values.filter { $0.hasPrefix("<\(kind):") }.count
            let name = "<\(kind):\(count + 1)>"
            names[text] = name
            return .string(name)
        case .array(let items):
            return .array(items.map { rename($0, &names) })
        case .object(let members):
            var out: [String: JSONValue] = [:]
            for (key, item) in members.sorted(by: { $0.key < $1.key }) {
                out[key] = rename(item, &names)
            }
            return .object(out)
        default:
            return value
        }
    }

    /// `id` for a prefixed ULID id (`run_01J…`), `time` for a timestamp, otherwise nil.
    static func kind(of text: String) -> String? {
        if let underscore = text.firstIndex(of: "_") {
            let body = text[text.index(after: underscore)...]
            let prefix = text[..<underscore]
            if body.count == 26, !prefix.isEmpty, prefix.allSatisfy(\.isLowercase),
                body.allSatisfy({ $0.isNumber || $0.isUppercase })
            {
                return "id"
            }
        }
        if text.count >= 20, text.contains("T"), Timestamp(text) != nil { return "time" }
        return nil
    }
}
