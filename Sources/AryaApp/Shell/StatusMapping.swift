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
