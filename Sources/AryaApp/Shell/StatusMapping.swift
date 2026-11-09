import Arya
import AryaDesign
import CoreGraphics

/// How facade states appear as AryaDesign statuses.
enum StatusMapping {
    static func status(of steward: StewardSummary, runs: [RunSummary]) -> AryaStatus {
        switch steward.status {
        case .paused: return .paused
        case .retired: return .idle
        case .active: return runs.contains { $0.status == .running } ? .running : .idle
        }
    }

    /// A run's rail label, numbered from 1 in start order ("run 14"), because run ids are long
    /// and opaque. `position` counts from the newest run, as the rail lists them.
    static func runLabel(position: Int, of count: Int) -> String {
        "run \(count - position)"
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
