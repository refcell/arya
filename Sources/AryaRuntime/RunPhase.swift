// The run state machine (ARCHITECTURE.md "Runs"). The run loop feeds it inputs and records an
// event for each accepted transition; anything the machine rejects is a runtime bug, never a
// silent state change.

/// Why a run failed. Raw values are the `reason` recorded on `run.failed`.
public enum RunFailureReason: String, Codable, Sendable, CaseIterable {
    /// The adapter process exited before sending `run/result`.
    case adapterExited = "adapter_exited"
    /// No adapter message arrived within `limits.timeoutSeconds`.
    case timeout
    /// `run/result` did not match the result schema.
    case invalidResult = "invalid_result"
    /// A budget (`maxTurns`, `maxCostMicros`) was exceeded.
    case budget
    /// The process running the run went away (found on restart).
    case interrupted
    /// The adapter reported `status: failed` or a harness error.
    case adapterFailed = "adapter_failed"
}

/// How a run ended without failing. Raw values are recorded on `run.finished`.
public enum RunEndStatus: String, Codable, Sendable, CaseIterable {
    /// The adapter completed the work.
    case completed
    /// A person or arya stopped the run and the adapter returned a stopped result.
    case stopped
}

/// Where a run is in its lifecycle.
public enum RunPhase: Sendable, Hashable {
    /// `run.started` is recorded; the adapter is not yet running.
    case started
    /// The adapter accepted `run/start` and is streaming events.
    case running
    /// `run/result` arrived with the given end status; policy is disposing proposed actions.
    case disposing(RunEndStatus)
    /// `run.finished` is recorded.
    case finished(RunEndStatus)
    /// `run.failed` is recorded.
    case failed(RunFailureReason)

    /// True once the run has finished or failed.
    public var isTerminal: Bool {
        switch self {
        case .finished, .failed: true
        case .started, .running, .disposing: false
        }
    }
}

/// An input that may move a run to a new phase.
public enum RunInput: Sendable, Hashable {
    /// The adapter answered `run/start`.
    case adapterStarted
    /// The adapter streamed an event.
    case adapterEvent
    /// A valid `run/result` arrived with this end status.
    case resultReceived(RunEndStatus)
    /// Every proposed action has a disposition.
    case dispositionsRecorded
    /// The run cannot continue.
    case fail(RunFailureReason)
}

/// A transition the state machine does not allow.
public struct RunTransitionError: Error, Equatable, Sendable {
    /// The phase the run was in.
    public var from: RunPhase
    /// The rejected input.
    public var input: RunInput
}

extension RunPhase {
    /// The phase after `input`, or an error if the transition is not allowed.
    public func applying(_ input: RunInput) throws(RunTransitionError) -> RunPhase {
        switch (self, input) {
        case (.started, .adapterStarted):
            return .running
        case (.running, .adapterEvent):
            return .running
        case (.running, .resultReceived(let status)):
            return .disposing(status)
        case (.disposing(let status), .dispositionsRecorded):
            return .finished(status)
        case (let phase, .fail(let reason)) where !phase.isTerminal:
            return .failed(reason)
        default:
            throw RunTransitionError(from: self, input: input)
        }
    }
}
