import AryaCore
import AryaRuntime
import Foundation

// Triggers for `arya serve` (M4): interval triggers fire from a loop that only one process per
// home runs (`<home>/scheduler.lock`), and messages from people start message runs.

extension Workspace {
    /// Starts firing interval triggers every `interval`. Returns false, and starts nothing,
    /// when another process already serves this home; true when this process now serves (or
    /// already did). With `demoPace`, it also starts a paced demo run every 20 to 40 seconds
    /// (runtime decision 0051), checking every 2 seconds.
    @discardableResult
    public func startServing(every interval: Duration = .seconds(30), demoPace: Bool = false)
        throws -> Bool
    {
        if serving != nil { return true }
        guard let lock = try SchedulerLock.acquire(home: home) else { return false }
        let scheduler = scheduler
        let heartbeat = Self.tickFile(home)
        let pause = demoPace ? min(interval, .seconds(2)) : interval
        // Follow-up checks of executed actions through each binding's `outcome` tool (runtime
        // decision 0054): an hour after an action, or a minute under demo pace.
        let outcomes = OutcomeChecker(
            sink: sink, delay: demoPace ? 60_000 : FollowUps.delay,
            connect: BindingActionExecutor.spawn)
        let task = Task {
            if demoPace { await scheduler.setDemoPace(DemoPacer()) }
            // A tick fails only when the ledger cannot be read; keep trying at the next one.
            while !Task.isCancelled {
                let now = ambient.now()
                _ = try? await scheduler.pace(now: now)
                _ = try? await outcomes.check(now: now)
                if (try? await scheduler.tick(now: now)) != nil {
                    try? Data(String(now.millis).utf8).write(to: heartbeat, options: .atomic)
                }
                // Periodic reports that came due (connect lane, `Reports.swift`).
                _ = try? await self.sendDueReports()
                try? await Task.sleep(for: pause)
            }
        }
        serving = (lock, task)
        return true
    }

    /// Stops the trigger loop, waits for the runs it started, and releases the lock.
    public func stopServing() async {
        guard let current = serving else { return }
        serving = nil
        current.task.cancel()
        await current.task.value
        await scheduler.settle()
        current.lock.release()
    }

    /// True while this process fires triggers for the home.
    public var isServing: Bool { serving != nil }

    /// One scheduler pass: starts a scheduled run for every due steward and returns their ids.
    /// The runs continue in the background; `settle()` waits for them.
    @discardableResult
    public func tick() async throws -> [String] {
        try await scheduler.tick(now: ambient.now()).map(\.rawValue)
    }

    /// Delivers a message from a person (a person binding id such as `person:alex`) to a
    /// steward. It starts a message run, with that person as actor, when the steward takes live
    /// triggers and has a `message` trigger for the sender; otherwise it records nothing and
    /// returns false.
    @discardableResult
    public func deliverMessage(_ text: String, from person: String, to steward: String)
        async throws -> Bool
    {
        let id = try await existing(steward).id
        return try await scheduler.deliver(text, from: person, to: id)
    }

    /// Waits for every run the scheduler started so far (triggered and message runs).
    public func settle() async {
        await scheduler.settle()
    }
}

/// Where triggers stand for the home: who serves, when the loop last ticked, and each
/// steward's next wake.
public struct ServeStatus: Sendable, Hashable, Codable {
    /// One steward's schedule.
    public struct Steward: Sendable, Hashable, Codable {
        public var steward: String
        public var name: String
        /// `off` (not ready or paused), `unscheduled` (no interval trigger), `running`, `due`,
        /// or `waiting`.
        public var state: String
        public var intervalSeconds: Int?
        public var nextWake: TimeText?
    }

    /// True when some process (this one or `arya serve`) fires triggers for the home.
    public var serving: Bool
    /// True when this process is the one serving.
    public var servingHere: Bool
    /// When a serving loop last finished a tick, from any process.
    public var lastTick: TimeText?
    /// Stewards that are not retired, by name.
    public var stewards: [Steward]
}

extension Workspace {
    static func tickFile(_ home: URL) -> URL { home.appendingPathComponent("scheduler.tick") }

    /// Who serves the home, the last tick, and each steward's next scheduled wake.
    public func serveStatus(timeZone: TimeZone = .current) async throws -> ServeStatus {
        let now = ambient.now()
        func time(_ date: Date) -> TimeText { TimeText(date, now: now.date, timeZone: timeZone) }
        let runs = try await runBook()
        let stewards = try await stewardBook().all.filter { $0.status != .retired }
            .sorted {
                $0.charter.name.localizedStandardCompare($1.charter.name) == .orderedAscending
            }
            .map { record in
                let status = SchedulePlan.status(of: record, runs: runs, now: now)
                return ServeStatus.Steward(
                    steward: record.id.rawValue, name: record.charter.name,
                    state: status.state.rawValue, intervalSeconds: status.intervalSeconds,
                    nextWake: status.nextWake.map { time($0.date) })
            }
        let tick = (try? String(contentsOf: Self.tickFile(home), encoding: .utf8))
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { Timestamp(millis: $0).date }
        return ServeStatus(
            serving: serving != nil || SchedulerLock.isHeld(home: home),
            servingHere: serving != nil, lastTick: tick.map(time), stewards: stewards)
    }
}

/// What sending a message to a steward did.
public struct MessageReceipt: Sendable, Hashable, Codable {
    /// The recorded `inbox.message` event.
    public var event: String
    /// The memory note a correction became; nil when it repeats a live note or is not one.
    public var note: String?
    /// The run that answered an ask or took a handoff; nil for a correction.
    public var run: RunSummary?
}

extension Workspace {
    /// Sends a person's message to a steward through its inbox. `intent` is `ask` (a question
    /// or request), `correct` (kept as memory, no run), or `handoff` (work for the steward).
    /// Ask and handoff start a live run on the message, with the person as actor, and wait for
    /// it. `person` is a person binding id, or `local` for the person at this machine.
    public func message(
        steward: String, text: String, intent: String = "ask", by person: String = "local"
    ) async throws -> MessageReceipt {
        let id = try await existing(steward).id
        guard let kind = MessageIntent(rawValue: intent) else {
            throw WorkspaceError.rejected("intent must be ask, correct, or handoff, not \(intent)")
        }
        let inbox = Inbox(engine: engine, scheduler: scheduler)
        let receipt: InboxReceipt
        do {
            receipt = try await inbox.record(text, from: person, to: id, intent: kind)
        } catch let error as InboxError {
            switch error {
            case .emptyText: throw WorkspaceError.rejected("a message needs text")
            case .unknownSender(let sender):
                throw WorkspaceError.rejected("\(sender) is not a person binding of \(steward)")
            default: throw WorkspaceError.rejected(String(describing: error))
            }
        }
        var run: RunSummary?
        if kind != .correct {
            let request = RunRequest(
                steward: id, input: Inbox.runInput(receipt, from: person, intent: kind),
                mode: .live, actor: .person(person))
            let outcome = try await mapped { try await engine.run(request) }
            try await routineRecorder.record(outcome)
            run = try await runBook().records[outcome.run].map(RunSummary.init)
        }
        return MessageReceipt(
            event: receipt.message.rawValue, note: receipt.note?.rawValue, run: run)
    }

    /// Runs the steward now (the app's ⌘↩), with `note` as the run's input when given.
    public func runNow(steward: String, note: String? = nil) async throws -> RunSummary {
        try await startRun(steward: steward, input: note ?? "")
    }
}

/// One entry of a steward's conversation with people.
public struct ConversationEntry: Sendable, Hashable, Codable {
    /// `inbound` (a person's message) or `outbound` (the steward's delivery to a person).
    public var direction: String
    /// The person binding id, or `local`.
    public var person: String
    public var channel: String
    /// `ask`, `correct`, or `handoff`, for inbound messages.
    public var intent: String?
    public var text: String?
    /// The run that sent an outbound entry.
    public var run: String?
    public var seq: Int
    public var time: TimeText
}

extension Workspace {
    /// A steward's conversation with people, newest last: messages to it and what it sent back
    /// through person bindings; with `person`, only that person's thread.
    public func conversation(
        steward: String, person: String? = nil, timeZone: TimeZone = .current
    ) async throws -> [ConversationEntry] {
        let record = try await existing(steward)
        let id = record.id
        let now = now()
        let people = Set(record.charter.bindings.filter { $0.kind == .person }.map(\.id))
        let thread = try InboxBook(try facadeState().runtime, people: [id: people])
            .threads[id, default: []]
        return thread.filter { person == nil || $0.person == person }.map {
            ConversationEntry(
                direction: $0.direction.rawValue, person: $0.person, channel: $0.channel,
                intent: $0.intent?.rawValue, text: $0.text, run: $0.run?.rawValue, seq: $0.seq,
                time: TimeText($0.at.date, now: now, timeZone: timeZone))
        }
    }
}
