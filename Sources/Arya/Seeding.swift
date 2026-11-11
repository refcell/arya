import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation

// Seeding: one process writes a demo home's whole history (decision 0052). Every adapter is
// the fake adapter served in process from a script held in memory, so a run costs no process
// launch, and the caller moves the clock between steps with `Ambient.advance(to:)`.

extension Workspace {
    /// Opens `home` with every charter's adapter served in process by the fake adapter, from
    /// `scripts` by adapter name; a charter naming another adapter fails its run. Actions
    /// succeed without calling a binding (`SeededExecutor`), since seeded history stands for
    /// work that happened. For tools that seed demo homes.
    public static func openForSeeding(
        home: URL, ambient: Ambient, scripts: [String: FakeScript]
    ) async throws -> Workspace {
        try HomeLayout.create(at: home)
        let leases = try FileRunLeases(directory: HomeLayout.leases(home))
        return try await open(
            home: home,
            wiring: Wiring(
                ambient: ambient,
                adapters: ScriptAdapterFactory(scripts: scripts, ambient: ambient),
                executor: SeededExecutor(ambient: ambient), leases: leases))
    }
}

/// Serves each run from the in-memory script its charter's adapter names, paced on the
/// seeding clock so its steps read as real work (`PacedAdapter`).
struct ScriptAdapterFactory: AdapterFactory {
    let scripts: [String: FakeScript]
    let ambient: Ambient

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        guard let script = scripts[charter.adapter] else {
            throw WorkspaceError.rejected("no seeding script for adapter \(charter.adapter)")
        }
        return PacedAdapter(
            FakeAdapter(script: script), ambient: ambient,
            tempo: SeedPace.tempo(charter.adapter))
    }
}

/// Seeded run timing on the virtual clock (decision 0052): each step lands 3-40 s after the
/// one before, varied by event kind and by a per-steward tempo, and a run takes 30 s to 6 min.
enum SeedPace {
    static let minimumRun: Int64 = 30_000
    static let maximumRun: Int64 = 360_000

    /// 0.7...1.9, stable per adapter name, so some stewards work briskly and some slowly.
    static func tempo(_ name: String) -> Double {
        let hash = name.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return 0.7 + Double(hash % 13) / 10
    }

    /// Seconds before an update, set on the received wire line (runtime stamps it first,
    /// then the parsed event): tool results wait on the tool, messages on writing.
    static func gap(_ update: AdapterUpdate) -> (range: ClosedRange<Int>, isResult: Bool)? {
        guard case .wire(let record) = update, record.direction == .received,
            let object = try? JSONSerialization.jsonObject(with: record.line) as? [String: Any]
        else { return nil }
        switch object["method"] as? String {
        case "run/result": return (4...25, true)
        case "run/event":
            let event = (object["params"] as? [String: Any])?["event"] as? [String: Any]
            switch event?["kind"] as? String {
            case "tool_call": return (3...8, false)
            case "tool_result": return (4...30, false)
            case "message": return (6...40, false)
            case "thinking": return (5...20, false)
            default: return (3...10, false)
            }
        default: return nil
        }
    }
}

/// Moves the seeding clock forward before handing runtime each update, so runtime stamps
/// every event seconds after the last instead of in the same millisecond. Pull-based: the
/// clock moves only when runtime asks for the next update.
struct PacedAdapter: Adapter {
    private let inner: any Adapter
    let updates: AsyncStream<AdapterUpdate>

    init(_ inner: any Adapter, ambient: Ambient, tempo: Double) {
        self.inner = inner
        let source = UpdateSource(inner.updates.makeAsyncIterator())
        let started = Locked<Int64?>(nil)
        updates = AsyncStream {
            guard let update = await source.next() else { return nil }
            let now = ambient.now().millis
            let start = started.withLock { value in
                if value == nil { value = now }
                return value ?? now
            }
            guard let (range, isResult) = SeedPace.gap(update) else { return update }
            let seconds = ambient.random(in: range.lowerBound..<(range.upperBound + 1))
            var gap = Int64(Double(seconds) * tempo * 1000)
            if isResult { gap = max(gap, SeedPace.minimumRun - (now - start)) }
            gap = min(gap, max(0, SeedPace.maximumRun - (now - start)))
            ambient.advance(to: Timestamp(millis: now + gap))
            return update
        }
    }

    func initialize(_ params: InitializeParams) async throws(AdapterError) -> InitializeResult {
        try await inner.initialize(params)
    }
    func start(_ params: RunStartParams) async throws(AdapterError) -> RunStartResult {
        try await inner.start(params)
    }
    func send(_ params: RunSendParams) async throws(AdapterError) { try await inner.send(params) }
    func stop(_ params: RunStopParams) async throws(AdapterError) { try await inner.stop(params) }
    func transcript(_ params: SessionParams) async throws(AdapterError) -> TranscriptResult {
        try await inner.transcript(params)
    }
    func cost(_ params: SessionParams) async throws(AdapterError) -> CostResult {
        try await inner.cost(params)
    }
    func shutdown() async throws(AdapterError) { try await inner.shutdown() }
    func answer(_ id: RPCID, _ result: HostAskResult) async throws(AdapterError) {
        try await inner.answer(id, result)
    }
    func answerDelegation(_ id: RPCID, _ result: HostDelegateResult) async throws(AdapterError) {
        try await inner.answerDelegation(id, result)
    }
}

/// Hands out one iterator's elements to a pull-based stream. Unchecked: runtime is its only
/// consumer and asks for one update at a time, so the iterator is never used concurrently.
private final class UpdateSource: @unchecked Sendable {
    private var iterator: AsyncStream<AdapterUpdate>.Iterator

    init(_ iterator: AsyncStream<AdapterUpdate>.Iterator) { self.iterator = iterator }

    func next() async -> AdapterUpdate? { await iterator.next() }
}

/// Seeded history stands for work that happened: each action succeeds (no binding is
/// called), so runtime's follow-up checks and Impact see executed actions, not drafts.
/// Each action takes 1-6 s on the seeding clock.
struct SeededExecutor: ActionExecutor {
    let ambient: Ambient

    func execute(_ request: ExecutionRequest) async -> ExecutionOutcome {
        let now = ambient.now().millis
        ambient.advance(to: Timestamp(millis: now + Int64(ambient.random(in: 1..<7)) * 1000))
        return .succeeded(output: ["seeded": true])
    }
}
