import AryaCore
import AryaEval
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation

/// The facade's projections, kept in memory and caught up by folding only the events appended
/// since the last read, so a read on a large home costs a few file stats when nothing changed
/// and the new events when something did.
struct FacadeState: Sendable {
    /// The newest event folded, and its hash.
    var seq: Int64 = 0
    var hash: String?
    var runs = RunBook()
    var stewards = StewardBook()
    var approvals = ApprovalBook()
    var actions = ActionIndex()
    /// Every live event, oldest first, in ledger and runtime form: reads fold these in memory
    /// instead of reading and decoding the ledger files again.
    var events: [Event] = []
    var runtime: [RuntimeEvent] = []
    /// Each run's events, oldest first, for run detail.
    var byRun: [RunID: [Event]] = [:]
    /// Each steward's events, oldest first, for per-steward reads (metrics, outcomes).
    var bySteward: [StewardID: [RuntimeEvent]] = [:]
    var rehearsals = RehearsalBook()
    var proposals = ProposalBook()
    var memory = MemoryProjection()
    var routines = RoutineLibrary()
    /// Each steward's charter by version, from the versions folded here (a book seeded from
    /// the disk cache has no older versions; readers fall back to the live charter).
    var charterVersions: [StewardID: [Int: Charter]] = [:]
    /// Step counts, last step titles, and run lengths, for `liveRuns()`.
    var live = LiveTally(keepSteps: false)
    /// Imported casebooks, oldest first.
    var casebooks: [CasebookSummary] = []
    /// When each steward's charter last changed (created or updated).
    var charterChanged: [StewardID: Date] = [:]
    /// Where each book was seeded from the disk cache; events up to it are already in it.
    var seeded: (runs: Int64, stewards: Int64, approvals: Int64) = (0, 0, 0)
    /// Events folded since the state was built, and times it was rebuilt (for tests).
    var applied = 0
    var rebuilds = 0

    mutating func apply(_ event: Event) throws {
        if event.seq > seeded.runs { try runs.apply(event) }
        if event.seq > seeded.stewards {
            try stewards.apply(event)
            if let steward = event.steward, let record = stewards.records[steward] {
                charterVersions[steward, default: [:]][record.version] = record.charter
            }
        }
        if event.seq > seeded.approvals { try approvals.apply(event) }
        fold(event)
        seq = event.seq
        hash = event.hash
        applied += 1
    }

    /// The position of the first event with `seq >= from` (live seqs are contiguous).
    func index(from seq: Int64) -> Int {
        guard let first = events.first?.seq else { return 0 }
        return min(events.count, max(0, Int(seq - first)))
    }

    /// When the event at `seq` happened, if it is live.
    func date(seq: Int) -> Date? {
        let index = index(from: Int64(seq))
        guard index < events.count, events[index].seq == Int64(seq) else { return nil }
        return events[index].at.date
    }

    /// Folds an event into everything but the seeded books.
    mutating func fold(_ event: Event) {
        let runtimeEvent = RuntimeEvent(event)
        actions.apply(event)
        events.append(event)
        runtime.append(runtimeEvent)
        if let steward = event.steward { bySteward[steward, default: []].append(runtimeEvent) }
        if let run = event.run { byRun[run, default: []].append(event) }
        try? rehearsals.apply(runtimeEvent)
        try? proposals.apply(runtimeEvent)
        try? memory.apply(event)
        try? routines.apply(event)
        live.add(event)
        if let casebook = Workspace.casebookSummary(event) { casebooks.append(casebook) }
        let type = event.type.rawValue
        if let steward = event.steward,
            type == StewardEventType.created || type == StewardEventType.charterUpdated
        {
            charterChanged[steward] = event.at.date
        }
    }
}

/// Actions as approvals need them: each proposal with its policy reason and risk, the actions
/// that executed (for "from → to" changes), and each run's recorded `run/result`.
struct ActionIndex: Sendable {
    struct Proposed: Sendable {
        var action: ProposedAction
        var reason: String
        var risk: Risk?
    }

    /// By "run:action".
    var proposed: [String: Proposed] = [:]
    /// Executed actions, oldest first.
    var executed: [ProposedAction] = []
    var results = RecordedResults()

    mutating func apply(_ event: Event) {
        guard let run = event.run?.rawValue else { return }
        if event.type == .actionProposed,
            let body = try? event.payload(as: ActionProposed.self)
        {
            proposed["\(run):\(body.action.id)"] = Proposed(
                action: body.action, reason: body.reason, risk: body.risk)
        } else if event.type == .actionExecuted,
            let body = try? event.payload(as: ActionExecuted.self),
            let action = proposed["\(run):\(body.action)"]?.action
        {
            executed.append(action)
        } else {
            results.add(event)
        }
    }
}

/// One `FacadeState` per open workspace, behind a lock.
final class FacadeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var state = FacadeState()
    private var built = false
    private var signature: [String] = []

    /// The state caught up with the ledger. When the folded events no longer continue (the
    /// head moved back, or the event after the last one folded does not chain to it, as after
    /// a restore), it rebuilds: books from the disk projection cache, which also covers a
    /// compacted ledger, then the events after them.
    func current(_ home: URL) throws -> FacadeState {
        lock.lock()
        defer { lock.unlock() }
        let reader = LedgerReader(home: home)
        let now = Self.signature(reader.directory)
        if built, now == signature { return state }
        if !built { try rebuild(home) }
        var broken = false
        var next = state
        try reader.forEach(from: state.seq + 1) { event in
            if broken { return }
            if let hash = next.hash, event.seq != next.seq + 1 || event.prev != hash {
                broken = true
                return
            }
            try next.apply(event)
        }
        if !broken, next.seq == state.seq, let hash = state.hash {
            // Nothing new, yet the files changed: the last event folded must still be there.
            var found: String?
            try reader.forEach(from: state.seq) { event in
                if found == nil, event.seq == state.seq { found = event.hash }
            }
            broken = found != hash
        }
        if broken {
            try rebuild(home)
            next = state
            try reader.forEach(from: state.seq + 1) { try next.apply($0) }
        }
        state = next
        signature = now
        return state
    }

    private func rebuild(_ home: URL) throws {
        let cache = ProjectionCache(home: home)
        let runs = try cache.current(RunBook.self, name: RunBook.cacheName)
        let stewards = try cache.current(StewardBook.self, name: StewardBook.cacheName)
        let approvals = try cache.current(ApprovalBook.self, name: ApprovalBook.cacheName)
        var fresh = FacadeState()
        fresh.rebuilds = state.rebuilds + (built ? 1 : 0)
        fresh.runs = runs.value
        fresh.stewards = stewards.value
        fresh.approvals = approvals.value
        fresh.seeded = (runs.seq, stewards.seq, approvals.seq)
        // The action index has no disk cache: fold it from the oldest live event up to the
        // least caught-up book; reads continue from there, and each book skips what it has.
        let reader = LedgerReader(home: home)
        let start = min(runs.seq, stewards.seq, approvals.seq)
        var versions = StewardBook()
        try reader.forEach { event in
            // Charter versions for proposal impact, which the seeded book does not keep.
            if let steward = event.steward, (try? versions.apply(event)) != nil,
                let record = versions.records[steward]
            {
                fresh.charterVersions[steward, default: [:]][record.version] = record.charter
            }
            guard event.seq <= start else { return }
            fresh.fold(event)
            if event.seq == start { fresh.hash = event.hash }
        }
        fresh.seq = start
        state = fresh
        built = true
    }

    /// Segment names with size and modification time: any append, new segment, or compaction
    /// changes it.
    static func signature(_ directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { name in
            var info = stat()
            guard stat(directory.appendingPathComponent(name).path, &info) == 0 else {
                return name
            }
            let modified = info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
            return "\(name):\(info.st_size):\(modified)"
        }
    }
}

/// A sink whose reads come from the facade's cached state and whose writes go to the ledger:
/// for read-mostly helpers (reports, casebooks) that take a sink and read every event.
struct CachedReadSink: EventSink {
    let workspace: Workspace
    let sink: LedgerEventSink

    func append(_ draft: RuntimeEventDraft) async throws -> RuntimeEvent {
        try await sink.append(draft)
    }

    func events(from seq: Int) async throws -> [RuntimeEvent] {
        let state = try workspace.facadeState()
        return Array(state.runtime[state.index(from: Int64(max(1, seq)))...])
    }

    func putBlob(_ data: Data) async throws -> String? { try await sink.putBlob(data) }
}
