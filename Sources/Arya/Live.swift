import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
import Foundation

/// One thing a run did, as a live view shows it: a message, a tool call or its output, a status
/// line, a decision, an action, or the run starting and ending.
public struct LiveStep: Sendable, Hashable, Codable {
    /// Ledger `seq` of the event the step came from.
    public var seq: Int
    public var run: String
    /// `started`, `message`, `thinking`, `tool_call`, `output` (a chunk of a tool's output, as
    /// it streams), `tool_result`, `status`, `error`,
    /// `decision`, `action`, `approval`, `finished`, `failed`, or an adapter's own kind.
    public var kind: String
    /// One line: "Called search", "Proposed label on MSG-9", "Finished".
    public var title: String
    /// The body: message text, tool input or output (pretty JSON), a status detail.
    public var text: String?
    /// Tool name, for tool calls.
    public var tool: String?
    /// Pairs a tool result with its call.
    public var callID: String?
    /// True for a failing tool result, an error, or a failed run or action.
    public var isError: Bool
    public var time: Date
}

/// What changed in one run since the previous update.
public struct LiveUpdate: Sendable, Hashable {
    public var run: String
    public var steward: String
    public var status: RunSummary.Status
    /// The new steps, oldest first; the first update of a stream carries every step so far.
    public var steps: [LiveStep]
    /// Steps so far in the run.
    public var stepCount: Int
    /// 0...1: steps so far against the steward's usual run length, capped at 0.95 while
    /// running and 1 once ended; nil without earlier finished runs to compare with.
    public var progress: Double?
}

/// A run in progress, for the sidebar and status bar.
public struct LiveRun: Sendable, Hashable {
    public var run: RunSummary
    public var stewardName: String
    public var stepCount: Int
    /// The newest step's title.
    public var lastStep: String?
    public var progress: Double?
    /// When it started.
    public var started: TimeText
    /// Seconds since it started (the workspace clock), as `runFacts` reports.
    public var elapsedSeconds: Double = 0
    /// The steward's usual steps per run, as `runFacts` reports.
    public var estimatedSteps: Int?
}

extension Workspace {
    /// Runs in progress, oldest first.
    public func liveRuns(timeZone: TimeZone = .current) async throws -> [LiveRun] {
        let running = try await runs().filter { $0.status == .running }.reversed()
        guard !running.isEmpty else { return [] }
        let names = Dictionary(
            try await stewards().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let tally = try facadeState().live
        let now = now()
        return running.map { run in
            let id = RunID(unchecked: run.id)
            return LiveRun(
                run: run, stewardName: names[run.steward] ?? run.steward,
                stepCount: tally.counts[id] ?? 0, lastStep: tally.lastTitle[id],
                progress: tally.progress(run: id, steward: StewardID(unchecked: run.steward)),
                started: TimeText(run.startedAt, now: now, timeZone: timeZone),
                elapsedSeconds: max(0, now.timeIntervalSince(run.startedAt)),
                estimatedSteps: tally.usualSteps(steward: StewardID(unchecked: run.steward)))
        }
    }

    /// Follows one run live: the first update carries every step so far, then one update per
    /// batch of new steps, as the ledger file changes. Ends after the run ends.
    public nonisolated func observe(run: String) -> AsyncStream<LiveUpdate> {
        let id = RunID(unchecked: run)
        return observe { $0.run == id }
    }

    /// Follows every run of one steward live, starting with the runs already in the ledger.
    /// Never ends on its own; stop consuming to end it.
    public nonisolated func observe(steward: String) -> AsyncStream<LiveUpdate> {
        let id = StewardID(unchecked: steward)
        return observe(endsWithRun: false) { $0.steward == id }
    }

    nonisolated func observe(
        endsWithRun: Bool = true, fallback: Duration = .seconds(1),
        _ matches: @escaping @Sendable (Event) -> Bool
    ) -> AsyncStream<LiveUpdate> {
        let reader = reader
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let signals = LedgerWatch.signals(directory: reader.directory, fallback: fallback)
            let task = Task {
                var tally = LiveTally(keepSteps: false)
                var next: Int64 = 1
                func pass() -> Bool {
                    var changed: [RunID: [LiveStep]] = [:]
                    var order: [RunID] = []
                    try? reader.forEach(from: next) { event in
                        next = event.seq + 1
                        let added = tally.add(event)
                        guard matches(event), let run = event.run, !added.isEmpty else { return }
                        if changed[run] == nil { order.append(run) }
                        changed[run, default: []] += added
                    }
                    for run in order {
                        guard let steward = tally.stewards[run] else { continue }
                        let status = tally.status[run] ?? .running
                        continuation.yield(
                            LiveUpdate(
                                run: run.rawValue, steward: steward.rawValue, status: status,
                                steps: changed[run] ?? [],
                                stepCount: tally.counts[run] ?? 0,
                                progress: tally.progress(run: run, steward: steward)))
                        if endsWithRun, status != .running { return true }
                    }
                    return false
                }
                if pass() { return continuation.finish() }
                for await _ in signals {
                    if Task.isCancelled || pass() { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Folds ledger events into live steps per run, with run status and step counts.
struct LiveTally: Sendable {
    /// False keeps only counts and last titles (the cached tally behind `liveRuns()`).
    var keepSteps = true
    private(set) var steps: [RunID: [LiveStep]] = [:]
    private(set) var counts: [RunID: Int] = [:]
    private(set) var lastTitle: [RunID: String] = [:]
    private(set) var stewards: [RunID: StewardID] = [:]
    private(set) var status: [RunID: RunSummary.Status] = [:]
    /// Step counts of ended runs, per steward, oldest first.
    private(set) var ended: [StewardID: [Int]] = [:]
    /// Tool calls and results already shown, by "run:call": the adapter's wire record and the
    /// runtime's `run.step.*` events describe the same call, and only the first is shown.
    private var calls: Set<String> = []
    private var results: Set<String> = []

    /// The median steps of the steward's last five ended runs, when any ended.
    func usualSteps(steward: StewardID) -> Int? {
        let recent = (ended[steward] ?? []).suffix(5).sorted()
        return recent.isEmpty ? nil : max(1, recent[recent.count / 2])
    }

    /// Steps so far against the steward's usual run length.
    func progress(run: RunID, steward: StewardID) -> Double? {
        let state = status[run] ?? .running
        if state != .running { return 1 }
        guard let usual = usualSteps(steward: steward) else { return nil }
        return min(0.95, Double(counts[run] ?? 0) / Double(usual))
    }

    @discardableResult
    mutating func add(_ event: Event) -> [LiveStep] {
        guard let run = event.run else { return [] }
        if let steward = event.steward { stewards[run] = steward }
        let made = Self.steps(event, run: run).filter { step in
            guard let call = step.callID.map({ "\(run.rawValue):\($0)" }) else { return true }
            switch step.kind {
            case "tool_call": return calls.insert(call).inserted
            case "output": return !results.contains(call)
            case "tool_result": return results.insert(call).inserted
            default: return true
            }
        }
        guard let newest = made.last else { return [] }
        if keepSteps { steps[run, default: []] += made }
        counts[run, default: 0] += made.count
        lastTitle[run] = newest.title
        let type = event.type.rawValue
        if type == RunEventType.finished || type == RunEventType.failed {
            status[run] = type == RunEventType.finished ? .finished : .failed
            if let steward = stewards[run] {
                ended[steward, default: []].append(counts[run] ?? 0)
            }
        } else if status[run] == nil {
            status[run] = .running
        }
        return made
    }

    static func steps(_ event: Event, run: RunID) -> [LiveStep] {
        let payload = event.payload
        func step(
            _ kind: String, _ title: String, text: String? = nil, tool: String? = nil,
            callID: String? = nil, isError: Bool = false
        ) -> [LiveStep] {
            [
                LiveStep(
                    seq: Int(event.seq), run: run.rawValue, kind: kind, title: title, text: text,
                    tool: tool, callID: callID, isError: isError, time: event.at.date)
            ]
        }
        switch event.type.rawValue {
        case RunEventType.started:
            let input = payload["input"]?["text"]?.stringValue
            return step("started", "Started", text: input)
        case RunEventType.finished:
            return step("finished", "Finished", text: payload["summary"]?.stringValue)
        case RunEventType.failed:
            let reason = payload["reason"]?.stringValue ?? "failed"
            return step(
                "failed", "Failed: \(reason.replacingOccurrences(of: "_", with: " "))",
                text: payload["detail"]?.stringValue, isError: true)
        case RunEventType.decision:
            let decision = payload["decision"]
            let choice = decision?["choice"]?.stringValue ?? "?"
            let why = decision?["why"]?.stringValue ?? decision?["rationale"]?.stringValue
            return step("decision", "Decided \(choice)", text: why)
        case ActionEventType.proposed, ActionEventType.executed, ActionEventType.failed,
            ActionEventType.rejected:
            let action = payload["action"]
            let kind = action?["kind"]?.stringValue ?? "action"
            let target = action?["target"]?.stringValue.map { " on \($0)" } ?? ""
            let verb =
                switch event.type.rawValue {
                case ActionEventType.proposed: "Proposed"
                case ActionEventType.executed:
                    payload["dryRun"] == true ? "Drafted, not sent:" : "Did"
                case ActionEventType.failed: "Failed"
                default: "Held back"
                }
            return step(
                "action", "\(verb) \(kind)\(target)", text: action?["rationale"]?.stringValue,
                isError: event.type.rawValue == ActionEventType.failed)
        case RunEventType.adapterEvent:
            return adapterSteps(event, step: step)
        case StepEventType.started.rawValue:
            let tool = payload["tool"]?.stringValue ?? "tool"
            return step(
                "tool_call", "Called \(tool)", text: payload["input"]?.stringValue, tool: tool,
                callID: payload["step"]?.stringValue)
        case ToolRecordType.call.rawValue:
            let tool = payload["tool"]?.stringValue ?? "tool"
            return step(
                "tool_call", "Called \(tool)", text: payload["input"].map(pretty), tool: tool,
                callID: payload["id"]?.stringValue)
        case ToolRecordType.result.rawValue:
            let failed = payload["isError"]?.boolValue ?? false
            return step(
                "tool_result", failed ? "Tool failed" : "Tool output",
                text: payload["output"].map(pretty), callID: payload["id"]?.stringValue,
                isError: failed)
        case StepEventType.output.rawValue:
            let blob = payload["blob"]?.stringValue
            return step(
                "output", blob == nil ? "Output" : "Output (preview; full output kept)",
                text: payload["text"]?.stringValue, callID: payload["step"]?.stringValue)
        case StepEventType.finished.rawValue:
            let ok = payload["ok"]?.boolValue ?? true
            let millis = payload["millis"]?.intValue.map { " in \($0) ms" } ?? ""
            return step(
                "tool_result", (ok ? "Tool done" : "Tool failed") + millis,
                callID: payload["step"]?.stringValue, isError: !ok)
        default:
            return []
        }
    }

    private static func adapterSteps(
        _ event: Event,
        step: (String, String, String?, String?, String?, Bool) -> [LiveStep]
    ) -> [LiveStep] {
        guard let record = WireRecord(ledgerPayload: event.payload),
            case .notification(let notification)? = record.message,
            notification.method == RPCMethod.runEvent, let raw = notification.params,
            let params = try? CanonicalJSON.decode(
                RunEventParams.self, from: try CanonicalJSON.encode(raw))
        else { return [] }
        switch params.event.body {
        case .message(let role, let text):
            return step("message", role == "assistant" ? "Said" : "Message", text, nil, nil, false)
        case .thinking(let text):
            return step("thinking", "Thought", text, nil, nil, false)
        case .toolCall(let id, let tool, let input):
            return step("tool_call", "Called \(tool)", pretty(input), tool, id, false)
        case .toolResult(let id, let output, let isError):
            let title = isError ? "Tool failed" : "Tool output"
            return step("tool_result", title, pretty(output), nil, id, isError)
        case .status(let state, let detail):
            return step("status", state, detail, nil, nil, false)
        case .error(let message):
            return step("error", "Error", message, nil, nil, true)
        case .other(let kind, let fields):
            let text = fields["text"]?.stringValue ?? fields["chunk"]?.stringValue
            return step(kind, kind.replacingOccurrences(of: "_", with: " "), text, nil, nil, false)
        }
    }

    static func pretty(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        let data = try? JSONEncoder.pretty.encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Signals when the ledger directory or its newest segment file changes, through file-system
/// event sources, with a slow poll as a fallback for missed events (a segment created before
/// the watch, a file system without events). Signals coalesce: a burst is one signal.
final class LedgerWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "arya.ledger-watch")
    private let directory: URL
    private let signal: @Sendable () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedFile: String?
    private var timer: DispatchSourceTimer?

    init(directory: URL, fallback: Duration, signal: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.signal = signal
        queue.async { self.start(fallback: fallback) }
    }

    /// A stream of change signals; watching stops when the consumer stops.
    static func signals(directory: URL, fallback: Duration) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watch = LedgerWatch(directory: directory, fallback: fallback) {
                continuation.yield()
            }
            continuation.onTermination = { _ in watch.stop() }
        }
    }

    func stop() {
        queue.async {
            self.directorySource?.cancel()
            self.fileSource?.cancel()
            self.timer?.cancel()
            self.directorySource = nil
            self.fileSource = nil
            self.timer = nil
        }
    }

    private func start(fallback: Duration) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let millis =
            Int(fallback.components.seconds * 1000)
            + Int(fallback.components.attoseconds / 1_000_000_000_000_000)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(50, millis)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.directorySource == nil { self.watchDirectory() }
            self.watchNewestFile()
            self.signal()
        }
        timer.resume()
        self.timer = timer
        watchDirectory()
        watchNewestFile()
    }

    private func watchDirectory() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            self?.watchNewestFile()
            self?.signal()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func watchNewestFile() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let newest = names.filter({ $0.hasSuffix(".jsonl") }).max(),
            newest != watchedFile
        else { return }
        fileSource?.cancel()
        fileSource = nil
        watchedFile = nil
        let fd = open(directory.appendingPathComponent(newest).path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.signal() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
        watchedFile = newest
    }
}

/// The binding proxy's tool records (`run.tool.call`, `run.tool.result`).
enum ToolRecordType {
    static let call = EventType("run.tool.call")
    static let result = EventType("run.tool.result")
}
