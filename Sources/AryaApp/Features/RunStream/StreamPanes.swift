import AryaDesign
import SwiftUI

/// The compact status of a work card.
enum WorkMark: Hashable, Sendable {
    case ok, failed, running, waiting, idle
}

extension StreamStepText {
    /// "14:02:07", the step's wall-clock time in the given zone.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// The short uppercase tag of a conversation row ("decide", "think", "agent").
    static func tag(_ kind: StreamStep.Kind) -> String {
        switch kind {
        case .started: return "start"
        case .message(let role, _): return role == "user" ? "you" : "agent"
        case .thinking: return "think"
        case .status: return "status"
        case .error: return "error"
        case .decision: return "decide"
        case .finished: return "done"
        case .failed: return "failed"
        case .toolCall: return "tool"
        case .action: return "action"
        }
    }

    /// The mark for a work card: tool calls by result, actions by outcome.
    static func mark(_ kind: StreamStep.Kind) -> WorkMark {
        switch kind {
        case .toolCall(let call):
            guard call.output != nil else { return .running }
            return call.isError ? .failed : .ok
        case .action(let action):
            switch action.outcome {
            case .executed: return .ok
            case .failed, .rejected, .denied: return .failed
            case .awaitingApproval: return .waiting
            case .approved: return .running
            case .proposed: return .idle
            }
        default: return .idle
        }
    }
}
