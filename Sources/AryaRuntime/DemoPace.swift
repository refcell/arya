import AryaAdapters
import AryaCore
import Foundation

// Demo pace (decision 0051). `arya serve --demo-pace` keeps a demo home busy so a running app
// shows stewards at work: every 20 to 40 seconds the next ready, active steward (in turn)
// starts a live run on one of its own earlier inputs, cycling through them. The runs are real
// runs through the engine and the steward's adapter; only the choice of when and what is
// paced. A steward with no earlier input gets a scheduled check. The jitter comes from a
// seeded generator, so a test sees the same sequence every time.

/// Picks when and what the next paced demo run is.
public struct DemoPacer: Sendable {
    /// Shortest and longest wait between paced runs, in seconds.
    public var minSeconds: Int
    public var maxSeconds: Int
    private var state: UInt64
    private var next: Timestamp?
    private var turn = 0
    private var used: [StewardID: Int] = [:]

    /// Creates a pacer; `seed` fixes the jitter sequence.
    public init(minSeconds: Int = 20, maxSeconds: Int = 40, seed: UInt64 = 0x5EED) {
        self.minSeconds = max(1, minSeconds)
        self.maxSeconds = max(self.minSeconds, maxSeconds)
        state = seed
    }

    /// When the next paced run is due, once the first `due` call set it.
    public var nextAt: Timestamp? { next }

    /// The run to start at `now`, or nil when none is due or no steward is ready. The first
    /// call only sets the first due time (a short wait, so a fresh serve starts soon).
    public mutating func due(now: Timestamp, events: [RuntimeEvent]) throws -> RunRequest? {
        guard let at = next else {
            next = now.adding(milliseconds: 3000)
            return nil
        }
        guard now.millis >= at.millis else { return nil }
        next = now.adding(milliseconds: Int64(wait()) * 1000)
        let stewards = try StewardBook(events).all.filter { $0.takesLiveTriggers }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        guard !stewards.isEmpty else { return nil }
        let steward = stewards[turn % stewards.count].id
        turn += 1
        let inputs = Self.inputs(of: steward, in: try RunBook(events))
        guard !inputs.isEmpty else {
            return RunRequest(
                steward: steward, input: RunInput(kind: .schedule, text: "Scheduled run."),
                mode: .live, actor: .system)
        }
        let index = used[steward, default: 0]
        used[steward] = index + 1
        let input = inputs[index % inputs.count]
        return RunRequest(
            steward: steward, input: RunInput(kind: input.kind, text: input.text), mode: .live,
            actor: .system)
    }

    /// The distinct inputs of `steward`'s earlier top-level manual, scheduled, and message
    /// runs, oldest first.
    static func inputs(of steward: StewardID, in runs: RunBook) -> [RunInput] {
        var seen: Set<String> = []
        var inputs: [RunInput] = []
        let kinds: [String: RunInputKind] = [
            "manual": .manual, "schedule": .schedule, "message": .message,
        ]
        for run in runs.all where run.steward == steward && run.parent == nil && !run.rehearsal {
            guard let kind = kinds[run.trigger], !run.input.isEmpty,
                seen.insert(run.input).inserted
            else { continue }
            inputs.append(RunInput(kind: kind == .message ? .manual : kind, text: run.input))
        }
        return inputs
    }

    /// Seconds until the next run, in `minSeconds...maxSeconds` (SplitMix64).
    private mutating func wait() -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return minSeconds + Int(z % UInt64(maxSeconds - minSeconds + 1))
    }
}

extension Scheduler {
    /// Turns demo pace on (with `pacer`) or off (nil).
    public func setDemoPace(_ pacer: DemoPacer?) {
        demoPacer = pacer
    }

    /// Starts the paced demo run due at `now`, if demo pace is on and one is due, in the
    /// background; returns its steward.
    @discardableResult
    public func pace(now: Timestamp) async throws -> StewardID? {
        guard var pacer = demoPacer else { return nil }
        // Read the ledger only when a paced run is due, not on every serve pass (0057).
        let due = pacer.nextAt.map { now.millis >= $0.millis } ?? false
        let events = due ? try await engine.sink.events(from: 1) : []
        let request = try pacer.due(now: now, events: events)
        demoPacer = pacer
        guard let request else { return nil }
        launch(request) { _ in }
        return request.steward
    }
}
