import AryaCore
import Foundation

@testable import AryaAdapters

/// Shared builders for adapter tests.
enum Sample {
    static let client = PeerInfo(name: "arya", version: "0.1.0")

    static func start(_ text: String, run: String = "run_1", timeoutSeconds: Int? = nil)
        -> RunStartParams
    {
        RunStartParams(
            run: run, instructions: "Label new issues.", input: RunInput(kind: .case, text: text),
            workdir: NSTemporaryDirectory(), limits: RunLimits(timeoutSeconds: timeoutSeconds))
    }

    static let result: JSONValue = [
        "summary": "Labeled ISSUE-1.", "decisions": [["id": "d1", "choice": "bug"]],
    ]

    /// A script with one matched run that streams two events and completes.
    static let script = FakeScript(responses: [
        "triage ISSUE-1": FakeScript.Response(
            events: [
                RunEvent(.status(state: "working", detail: nil)),
                RunEvent(.message(role: "assistant", text: "It is a bug.")),
            ],
            result: result, cost: CostResult(inputTokens: 10, outputTokens: 5, costMicros: 42))
    ])

    /// A script whose default response is `response`.
    static func script(_ response: FakeScript.Response) -> FakeScript {
        FakeScript(defaultResponse: response)
    }

    /// Generous timeouts so a loaded machine never turns a slow but correct peer into a
    /// timeout or a SIGTERM. Tests about escalation shorten the one grace they exercise.
    static let timeouts = ConnectionTimeouts(
        request: .seconds(30), stopGrace: .seconds(10), killGrace: .seconds(5),
        exitGrace: .seconds(10))
}

/// Collects updates from an adapter until `.exited` or until `stop` returns true.
func collect(
    _ adapter: any Adapter, until stop: @Sendable (AdapterUpdate) -> Bool = { _ in false }
) async -> [AdapterUpdate] {
    var seen: [AdapterUpdate] = []
    for await update in adapter.updates {
        seen.append(update)
        if stop(update) { break }
    }
    return seen
}

extension AdapterUpdate {
    var isResult: Bool {
        if case .result = self { return true }
        return false
    }

    var event: RunEventParams? {
        if case .event(let params) = self { return params }
        return nil
    }

    var result: RunResultParams? {
        if case .result(let params) = self { return params }
        return nil
    }

    var wire: WireRecord? {
        if case .wire(let record) = self { return record }
        return nil
    }

    var exit: AdapterExit? {
        if case .exited(let exit) = self { return exit }
        return nil
    }
}

/// A ``SleepClock`` advanced by hand. `tick()` waits until something is sleeping on it, then
/// wakes it, so a test steps the idle timer exactly, whatever the machine load.
actor ManualClock: SleepClock {
    private var sleepers: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0
    private var tickWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = continuation
                let waiters = tickWaiters.values
                tickWaiters = [:]
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Waits for a sleeper, then ends every current sleep. Returns `false` when nothing starts
    /// sleeping within `limit` (the timer stopped, which the test then reports instead of
    /// hanging); the limit only matters when something is already wrong.
    func tick(waitingAtMost limit: Duration = .seconds(10)) async -> Bool {
        if sleepers.isEmpty {
            let id = nextID
            nextID += 1
            let timer = Task {
                try? await Task.sleep(for: limit)
                self.expireWaiter(id)
            }
            await withCheckedContinuation { tickWaiters[id] = $0 }
            timer.cancel()
        }
        guard !sleepers.isEmpty else { return false }
        let woken = sleepers.values
        sleepers = [:]
        for sleeper in woken { sleeper.resume() }
        return true
    }

    private func expireWaiter(_ id: Int) {
        tickWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancel(_ id: Int) {
        sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
