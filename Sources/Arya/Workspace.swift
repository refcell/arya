import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation

/// An opened arya home: the only API the CLI and the app use.
///
/// `Workspace.open(home:)` creates the home layout (ARCHITECTURE.md "Home directory"), opens the
/// ledger, fails runs whose process is gone, and wires the runtime and eval modules over it.
/// Every write records ledger events with the local user as actor. Ids are plain strings
/// (`st_…`, `run_…`, `ap_…`). State is read from the ledger at each call, so several
/// processes (the CLI and the app) can share one home.
///
/// Calls whose backing module has not landed yet throw `WorkspaceError.unavailable`; the
/// signatures are stable so callers can be written against them today.
public actor Workspace {
    /// The home directory this workspace reads and writes.
    public nonisolated let home: URL
    nonisolated let reader: LedgerReader
    let ambient: Ambient
    let sink: LedgerEventSink
    let approvalQueue: ApprovalQueue
    let dispatcher: ActionDispatcher
    let engine: RunEngine
    let routineRecorder: RoutineRecorder
    let scheduler: Scheduler
    /// Which runs a live process holds (shared with the engine and recovery).
    let leases: any RunLeases
    /// The trigger loop and the home's scheduler lock while this process serves.
    var serving: (lock: SchedulerLock, task: Task<Void, Never>)?

    private init(home: URL, wiring: Wiring) throws {
        self.home = home
        ambient = wiring.ambient
        leases = wiring.leases
        sink = try LedgerEventSink(home: home, ambient: wiring.ambient)
        reader = LedgerReader(home: home)
        approvalQueue = ApprovalQueue(sink: sink, ambient: wiring.ambient)
        dispatcher = ActionDispatcher(
            sink: sink, approvals: approvalQueue,
            executor: RoutineActionExecutor(
                home: home, fallback: wiring.executor, runner: wiring.routines))
        engine = RunEngine(
            sink: sink, ambient: wiring.ambient, adapters: wiring.adapters, dispatcher: dispatcher,
            approvals: approvalQueue,
            workdir: { run in
                let url = HomeLayout.work(home, run: run)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url.path
            },
            questionPoll: wiring.questionPoll, leases: wiring.leases, sandbox: wiring.sandbox)
        let recorder = RoutineRecorder(home: home, sink: sink)
        routineRecorder = recorder
        scheduler = Scheduler(engine: engine) { outcome in try? await recorder.record(outcome) }
    }

    /// Opens the home at `home`, creating its directories when missing, and records
    /// `run.failed(interrupted)` for runs whose process is gone.
    ///
    /// The caller (CLI or app entry point) resolves the home path, for example from
    /// `ARYA_HOME`, and passes `environment`, the complete environment adapter processes get
    /// (include `PATH` so profile commands without a slash resolve). This library never reads
    /// environment variables; it uses the real clock and randomness.
    public static func open(home: URL, environment: [String: String] = [:]) async throws
        -> Workspace
    {
        try await open(home: home, environment: environment, ambient: .live)
    }

    /// Opens with an explicit clock, for example `Ambient.fixed(start:stepMillis:)` weeks in the
    /// past, so a seeding tool can write history that reads as old.
    public static func open(home: URL, environment: [String: String] = [:], ambient: Ambient)
        async throws -> Workspace
    {
        try HomeLayout.create(at: home)
        let leases = try FileRunLeases(directory: HomeLayout.leases(home))
        return try await open(
            home: home,
            wiring: Wiring(
                ambient: ambient,
                adapters: ProfileAdapterFactory(home: home, environment: environment),
                executor: DryRunExecutor(), leases: leases))
    }

    /// Opens with explicit wiring (tests pass the fake adapter and a fixed ambient).
    static func open(home: URL, wiring: Wiring) async throws -> Workspace {
        try HomeLayout.create(at: home)
        let workspace = try Workspace(home: home, wiring: wiring)
        try await RunRecovery(sink: workspace.sink, leases: wiring.leases).recover()
        return workspace
    }

    // MARK: Stewards

    /// All stewards, sorted by id, including paused and retired ones.
    public func stewards() async throws -> [StewardSummary] {
        try await lifecycle.book().all.map(StewardSummary.init)
    }

    /// One steward, or `nil` if no steward has this id.
    public func steward(_ id: String) async throws -> StewardSummary? {
        try await record(id).map(StewardSummary.init)
    }

    /// The live charter of a steward as canonical JSON, effort changes included.
    public func charter(_ id: String) async throws -> Data {
        try CanonicalJSON.encode(try await existing(id).charter)
    }

    /// Records a new steward from charter JSON (`steward.created`, version 1).
    public func createSteward(charter: Data) async throws -> StewardSummary {
        let parsed: Charter
        do {
            parsed = try Charter.load(from: charter)
        } catch let error as CharterError {
            throw WorkspaceError.rejected(Self.describe(error))
        }
        return try await mapped { StewardSummary(try await lifecycle.create(parsed)) }
    }

    /// Pauses a steward so it takes no live triggers (`steward.paused`).
    public func pauseSteward(_ id: String) async throws {
        let steward = try await existing(id).id
        _ = try await mapped { try await lifecycle.pause(steward) }
    }

    /// Resumes a paused steward (`steward.resumed`).
    public func resumeSteward(_ id: String) async throws {
        let steward = try await existing(id).id
        _ = try await mapped { try await lifecycle.resume(steward) }
    }

    /// Retires a steward for good (`steward.retired`).
    public func retireSteward(_ id: String) async throws {
        let steward = try await existing(id).id
        _ = try await mapped { try await lifecycle.retire(steward) }
    }

    /// A steward's effort: `low`, `medium`, or `high` (decision 0026).
    public func effort(for steward: String) async throws -> String {
        try await existing(steward).charter.effort.rawValue
    }

    /// Changes a steward's effort (`steward.effort.set`, decision 0026). Effort is an
    /// operational setting: no proposal, no gate, no new charter version. `person` is the
    /// deciding person (`local` or a contact id).
    public func setEffort(_ effort: String, for steward: String, by person: String = "local")
        async throws
    {
        guard let value = Effort(rawValue: effort) else {
            throw WorkspaceError.rejected("effort must be low, medium, or high, not \(effort)")
        }
        let id = try await existing(steward).id
        _ = try await mapped { try await lifecycle.setEffort(value, for: id, by: .person(person)) }
    }

    // MARK: Runs

    /// Starts a manual run with `input` as its text and waits until it finishes or fails.
    /// Approvals it requests stay pending after it returns.
    /// Starts a manual live run with no input ("Run now"): the input is "Manual run.".
    public func startRun(steward: String) async throws -> RunSummary {
        try await startRun(steward: steward, input: "")
    }

    /// Starts a manual live run and waits for it to end. Blank input becomes "Manual run.".
    public func startRun(steward: String, input: String) async throws -> RunSummary {
        let id = try await existing(steward).id
        let blank = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = blank ? "Manual run." : input
        let outcome = try await mapped { try await engine.run(.manual(id, text: text)) }
        try await routineRecorder.record(outcome)
        guard let record = try await runBook().records[outcome.run] else {
            throw WorkspaceError.notFound(outcome.run.rawValue)
        }
        return RunSummary(record)
    }

    /// Runs, newest first, optionally for one steward. Rehearsal runs have trigger `case`.
    public func runs(steward: String? = nil) async throws -> [RunSummary] {
        try await runBook().all.reversed()
            .filter { steward == nil || $0.steward.rawValue == steward }
            .map(RunSummary.init)
    }

    // MARK: Approvals

    /// Approvals, oldest first; pending only unless `includeDecided` is true.
    public func approvals(includeDecided: Bool = false) async throws -> [ApprovalSummary] {
        let book = try await approvalQueue.book()
        return try await detailed(
            (includeDecided ? book.all : book.pending).map(ApprovalSummary.init))
    }

    /// One approval with its content, source item, and policy rule, or `nil`.
    public func approval(_ id: String) async throws -> ApprovalSummary? {
        guard let record = try await approvalQueue.book().records[ApprovalID(unchecked: id)]
        else { return nil }
        return try await detailed([ApprovalSummary(record)]).first
    }

    /// Adds each approval's source item (its run's input) and the policy verdict that held it.
    func detailed(_ approvals: [ApprovalSummary]) async throws -> [ApprovalSummary] {
        guard !approvals.isEmpty else { return approvals }
        let runs = try await runBook().records
        let wanted = Set(approvals.map(\.run))
        var reasons: [String: String] = [:]
        var risks: [String: Risk] = [:]
        var proposed: [String: ProposedAction] = [:]
        var executed: [(seq: Int, action: ProposedAction)] = []
        try reader.forEach { event in
            guard let run = event.run?.rawValue else { return }
            if event.type == .actionProposed {
                let body = try event.payload(as: ActionProposed.self)
                proposed["\(run):\(body.action.id)"] = body.action
                guard wanted.contains(run) else { return }
                reasons["\(run):\(body.action.id)"] = body.reason
                risks["\(run):\(body.action.id)"] = body.risk
            } else if event.type == .actionExecuted {
                let body = try event.payload(as: ActionExecuted.self)
                if let action = proposed["\(run):\(body.action)"] {
                    executed.append((Int(event.seq), action))
                }
            }
        }
        let actionIDs = try await approvalQueue.book().records
        let recorded = RecordedResults(try reader.events())
        let charters = Dictionary(
            try await lifecycle.book().all.map { ($0.id.rawValue, $0.charter) },
            uniquingKeysWith: { first, _ in first })
        return approvals.map { approval in
            var out = approval
            let run = RunID(unchecked: approval.run)
            out.source = runs[run]?.input
            if case .action(let action)? = actionIDs[ApprovalID(unchecked: approval.id)]?.subject {
                out.policyRule = reasons["\(approval.run):\(action.id)"]
                out.policyText = out.policyRule.map {
                    Self.policyText(
                        $0, action: action, charter: charters[approval.steward])
                }
                let wire = recorded.action(action.id, run: run)
                out.risk =
                    risks["\(approval.run):\(action.id)"]?.rawValue ?? wire?.risk?.rawValue
                out.why = wire?.why
                out.change = Self.change(action, after: executed.map(\.action))
                let rule = charters[approval.steward]?.policy.approverRule(for: action)
                out.approvers = rule?.people
                out.approverNote = rule?.note
            }
            return out
        }
    }

    /// A policy verdict reason (`rule:<action>`, `rule:routine:<name>@<v>`, `default`,
    /// `routine_default`) in a person's words, preferring the matching rule's `note`.
    static func policyText(_ reason: String, action: ProposedAction, charter: Charter?) -> String {
        let label = action.kind.prefix(1).uppercased() + action.kind.dropFirst()
        if reason.hasPrefix("rule:") {
            let name = String(reason.dropFirst("rule:".count))
            let rule = charter?.policy.rules.first {
                $0.action == name && ($0.binding == nil || $0.binding == action.binding)
            }
            if let note = rule?.note, !note.isEmpty { return note }
            return "\(label) actions need approval (charter rule)."
        }
        if reason.hasPrefix("autonomy:") {
            let parts = reason.split(separator: ":").map(String.init)
            let level = parts.count > 1 ? Autonomy(rawValue: parts[1]) : nil
            let risk = parts.count > 2 ? Risk(rawValue: parts[2]) : nil
            return autonomyText(level, risk: risk)
        }
        switch reason {
        case "default":
            return "Actions the charter does not name need approval."
        case "routine_default":
            return "A routine version needs approval until the charter names it."
        default:
            return "The steward's policy holds this action for a person."
        }
    }

    /// Why an autonomy level made an action wait, as a plain sentence.
    static func autonomyText(_ level: Autonomy?, risk: Risk?) -> String {
        let risky = risk.map { "this one is \($0.rawValue) risk" } ?? "this one may not be"
        switch level {
        case .observe:
            return "This steward only observes, so it takes no action without a person."
        case .suggest:
            return "This steward only suggests changes, so a person approves each action."
        case .actLow:
            return "This steward acts on low-risk actions only; \(risky), so it asks you."
        case .actMedium:
            return "This steward acts on low- and medium-risk actions only; "
                + (risk.map { "this one is \($0.rawValue) risk" } ?? "this one may be high risk")
                + ", so it asks you."
        case nil:
            return "This steward's autonomy level holds this action for a person."
        }
    }

    /// What an action would change: its scalar params against the same kind of action last
    /// executed on the same target (`label: none → billing`). Nil for replies and messages,
    /// whose content is the change, and for actions without scalar params.
    static func change(_ action: ProposedAction, after executed: [ProposedAction])
        -> ApprovalSummary.Change?
    {
        guard !["reply", "message", "comment", "send"].contains(action.kind),
            let params = action.params?.objectValue
        else { return nil }
        func scalar(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let text)?: text
            case .int(let number)?: String(number)
            case .double(let number)?: String(number)
            case .bool(let flag)?: String(flag)
            default: nil
            }
        }
        guard let key = params.keys.sorted().first(where: { scalar(params[$0]) != nil }),
            let to = scalar(params[key])
        else { return nil }
        let from = executed.last {
            $0.kind == action.kind && $0.target == action.target
                && scalar($0.params?.objectValue?[key]) != nil
        }.flatMap { scalar($0.params?.objectValue?[key]) }
        return .init(
            field: key, from: from, to: to, text: "\(key): \(from ?? "none") → \(to)")
    }

    /// Grants a pending approval; an action then executes with the steward's live charter and
    /// its output is recorded. For a question, `note` is the answer. `person` is who grants it
    /// (`local`, or a person binding id); the charter's `policy.approvers` must allow them, or
    /// `approval.refused` is recorded and the approval stays pending.
    public func approve(_ id: String, note: String? = nil) async throws -> ApprovalSummary {
        try await approve(id, note: note, as: RuntimeActor.localUser.id)
    }

    /// Grants a pending approval on behalf of `person` (see `approve(_:note:)`).
    public func approve(_ id: String, note: String? = nil, as person: String)
        async throws -> ApprovalSummary
    {
        try await checkApprover(id, person: person)
        let record = try await mapped {
            try await approvalQueue.grant(
                ApprovalID(unchecked: id), by: .person(person), note: note)
        }
        guard record.status == .granted else {
            throw WorkspaceError.rejected("\(id) is already \(record.status.rawValue)")
        }
        if case .action = record.subject {
            let charter = try await existing(record.steward.rawValue).charter
            let outcome = try await dispatcher.executeGranted(record, charter: charter)
            if let setback = Setback(record, executed: outcome) {
                await scheduler.replan(
                    after: record.run, steward: record.steward, setbacks: [setback])
            }
        }
        return try await detailed([ApprovalSummary(record)])[0]
    }

    /// Denies a pending approval (`approval.denied`, then `action.rejected`).
    public func deny(_ id: String, note: String? = nil) async throws -> ApprovalSummary {
        let record = try await mapped {
            try await approvalQueue.deny(ApprovalID(unchecked: id), by: .localUser, note: note)
        }
        guard record.status == .denied else {
            throw WorkspaceError.rejected("\(id) is already \(record.status.rawValue)")
        }
        try await dispatcher.rejectDecided(record)
        if let setback = Setback(record) {
            // The steward hears about the denial and may revise its plan (decision 0046).
            await scheduler.replan(after: record.run, steward: record.steward, setbacks: [setback])
        }
        return try await detailed([ApprovalSummary(record)])[0]
    }

    // MARK: Ledger

    /// Ledger entries with `seq >= from`, in order, at most `limit` of them.
    public func ledger(from seq: Int = 1, limit: Int? = nil) async throws -> [LedgerEntry] {
        var entries: [LedgerEntry] = []
        try reader.forEach(from: Int64(max(1, seq))) { event in
            if let limit, entries.count >= limit { return }
            entries.append(try LedgerEntry(event))
        }
        return entries
    }

    /// Entries with `seq >= from`, then every new entry as it is appended, by any process.
    /// The stream ends when the consumer stops iterating (its task is cancelled).
    public nonisolated func events(from seq: Int = 1) -> AsyncThrowingStream<LedgerEntry, Error> {
        let source = reader.follow(after: Int64(max(1, seq) - 1))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source { continuation.yield(try LedgerEntry(event)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Observation for views: yields the newest ledger `seq` whenever events after `seq` are
    /// appended, by this process or another one sharing the home. Only the newest value is
    /// buffered, so a burst (a run, a rehearsal) reaches a slow consumer as one refresh. Pass
    /// `lastSeq()` to skip what is already shown. The stream ends when the consumer stops or
    /// throws when the ledger cannot be read.
    public nonisolated func changes(after seq: Int = 0) -> AsyncThrowingStream<Int, Error> {
        let source = reader.follow(after: Int64(max(0, seq)))
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await event in source { continuation.yield(Int(event.seq)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The `seq` of the newest event, or 0 for an empty ledger.
    public func lastSeq() async throws -> Int {
        try await sink.events(from: 1).last?.seq ?? 0
    }

    /// Verifies the hash chain, `seq` continuity, and envelopes.
    public func verifyLedger() async throws -> LedgerCheck {
        let result = try LedgerVerifier(home: home).verify()
        guard let failure = result.failure else {
            return LedgerCheck(ok: true, events: Int(result.events))
        }
        return LedgerCheck(
            ok: false, events: Int(result.events), firstBadSeq: Int(result.events) + 1,
            detail: failure.description)
    }

    // MARK: Helpers

    var lifecycle: StewardLifecycle { StewardLifecycle(sink: sink) }

    func runBook() async throws -> RunBook {
        try RunBook(try await sink.events(from: 1))
    }

    func record(_ id: String) async throws -> StewardRecord? {
        try await lifecycle.book().records[StewardID(unchecked: id)]
    }

    func existing(_ id: String) async throws -> StewardRecord {
        guard let record = try await record(id) else { throw WorkspaceError.notFound(id) }
        return record
    }

    /// Runs `body`, turning runtime errors into facade errors.
    func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as StewardError {
            throw Self.facadeError(error)
        } catch let error as ApprovalError {
            switch error {
            case .notFound(let id): throw WorkspaceError.notFound(id.rawValue)
            case .alreadyDecided(let id, let status):
                throw WorkspaceError.rejected("\(id.rawValue) is already \(status.rawValue)")
            }
        } catch let error as RunError {
            switch error {
            case .stewardRetired(let id): throw WorkspaceError.rejected("\(id.rawValue) is retired")
            }
        }
    }

    static func facadeError(_ error: StewardError) -> WorkspaceError {
        switch error {
        case .notFound(let id): .notFound(id.rawValue)
        case .alreadyExists(let id): .rejected("steward \(id.rawValue) already exists")
        case .invalidCharter(let issues): .rejected(Self.describe(.invalid(issues)))
        case .idMismatch(let expected, let got):
            .rejected("charter is for \(got.rawValue), not \(expected.rawValue)")
        case .wrongStatus(let id, let status): .rejected("\(id.rawValue) is \(status.rawValue)")
        }
    }

    static func describe(_ error: CharterError) -> String {
        switch error {
        case .malformed(let detail): "charter does not decode: \(detail)"
        case .invalid(let issues):
            "invalid charter: " + issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
        }
    }
}

/// What `Workspace` runs on: clock and ids, adapters, the action executor, and run leases.
struct Wiring: Sendable {
    var ambient: Ambient
    var adapters: any AdapterFactory
    var executor: any ActionExecutor
    var leases: any RunLeases
    var questionPoll: Duration = .milliseconds(250)
    /// Runs `routine` actions' scripts, sandboxed in the run's workdir (decision 0040).
    var routines: any RoutineRunning = SandboxedRoutineRunner()
    /// Records the sandbox on `run.started` and confines binding proxies' servers.
    var sandbox = true
}

/// Errors the facade reports.
public enum WorkspaceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The call's backing module has not landed yet.
    case unavailable(String)
    /// No steward, run, or approval has this id.
    case notFound(String)
    /// The request was rejected, for example an invalid charter or an approval already decided.
    case rejected(String)

    public var description: String {
        switch self {
        case .unavailable(let call): "\(call) is not available yet"
        case .notFound(let id): "not found: \(id)"
        case .rejected(let detail): detail
        }
    }
}

/// Creates the directories of an arya home.
enum HomeLayout {
    static let directories = ["ledger", "blobs", "casebooks", "cache"]

    static func create(at home: URL) throws {
        for name in directories {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    /// Scratch directory of one run (adapter workdir and routine workdir).
    static func work(_ home: URL, run: RunID) -> URL {
        home.appendingPathComponent("cache/work/\(run.rawValue)", isDirectory: true)
    }

    /// Where run leases live (`cache/runs/<run>.lock`).
    static func leases(_ home: URL) -> URL {
        home.appendingPathComponent("cache/runs", isDirectory: true)
    }
}
