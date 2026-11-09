import Arya
import AryaDesign
import CoreGraphics
import Foundation

/// How facade states appear as AryaDesign statuses.
enum StatusMapping {
    static func status(of steward: StewardSummary, runs: [RunSummary]) -> AryaStatus {
        switch steward.status {
        case .paused: return .paused
        case .retired: return .idle
        case .active: return runs.contains { $0.status == .running } ? .running : .idle
        }
    }

    /// A run's thread title (STYLE.md Thread row): the first line of its summary, else its
    /// trigger ("manual run"). Never a run number or id.
    static func threadTitle(of run: RunSummary) -> String {
        let summary =
            run.summary?.split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !summary.isEmpty { return summary }
        let trigger = run.trigger.trimmingCharacters(in: .whitespaces)
        return trigger.isEmpty ? "run" : "\(trigger) run"
    }

    static func status(of run: RunSummary) -> AryaStatus {
        switch run.status {
        case .running: .running
        case .finished: .done
        case .failed: .failed
        }
    }
}

/// The rail's width, resizable within STYLE.md's bounds.
enum RailWidth {
    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, AryaSize.railMinWidth), AryaSize.railMaxWidth)
    }
}
