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

    static let fast = ConnectionTimeouts(
        request: .seconds(5), stopGrace: .milliseconds(200), killGrace: .milliseconds(200),
        exitGrace: .milliseconds(500))
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
