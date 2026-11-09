import AryaCore
import AryaRuntime
import Foundation

// Triggers for `arya serve` (M4): interval triggers fire from a loop that only one process per
// home runs (`<home>/scheduler.lock`), and messages from people start message runs.

extension Workspace {
    /// Starts firing interval triggers every `interval`. Returns false, and starts nothing,
    /// when another process already serves this home; true when this process now serves (or
    /// already did).
    @discardableResult
    public func startServing(every interval: Duration = .seconds(30)) throws -> Bool {
        if serving != nil { return true }
        guard let lock = try SchedulerLock.acquire(home: home) else { return false }
        let scheduler = scheduler
        let task = Task {
            // A tick fails only when the ledger cannot be read; keep trying at the next one.
            while !Task.isCancelled {
                _ = try? await scheduler.tick(now: ambient.now())
                try? await Task.sleep(for: interval)
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
