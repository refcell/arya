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

    /// The sidebar dot for a steward (STYLE.md Sidebar): paused first, then needs you, then
    /// running, then on or off track against its metric, else idle.
    static func health(
        of steward: StewardSummary, runs: [RunSummary], pending: Int, onTrack: Bool?
    ) -> AryaStatus {
        switch steward.status {
        case .paused: return .paused
        case .retired: return .idle
        case .active:
            if pending > 0 { return .needsYou }
            if runs.contains(where: { $0.status == .running }) { return .running }
            switch onTrack {
            case true?: return .onTrack
            case false?: return .offTrack
            case nil: return .idle
            }
        }
    }

    /// "0.96 / 0.95", the latest metric against its target, for the selected steward's row.
    static func metricSuffix(latest: Double?, target: Double?) -> String? {
        guard let latest, let target else { return nil }
        func number(_ value: Double) -> String {
            value.rounded() == value && abs(value) >= 10
                ? String(Int(value)) : String(format: "%.2f", value)
        }
        return "\(number(latest)) / \(number(target))"
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
