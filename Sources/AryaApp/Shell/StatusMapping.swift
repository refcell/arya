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

    /// How a steward's sidebar row reads (STYLE.md Sidebar). The dot carries attention only:
    /// orange with pending approvals, else neutral (a ring when paused). The text carries
    /// health: a behind-target steward always shows its metric in the negative tone; an
    /// on-track one shows it muted only when selected; paused shows the word.
    struct SidebarRow: Equatable {
        enum Health: Int, Comparable {
            case needsYou, behind, onTrack, paused
            static func < (lhs: Health, rhs: Health) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        var status: AryaStatus
        var health: Health
        var trailing: String?
        var trailingIsAlert: Bool
        var trailingIsMono: Bool
        var accessibility: String

        init(
            _ steward: StewardSummary, pending: Int, latest: Double?, target: Double?,
            onTrack: Bool?, isSelected: Bool
        ) {
            let value = latest.map(StatusMapping.metric)
            let behind = onTrack == false && steward.status != .paused
            var spoken = [steward.name]
            if steward.status == .paused {
                status = .paused
                health = .paused
                trailing = "paused"
                trailingIsMono = false
                spoken.append("paused")
            } else {
                status = pending > 0 ? .needsYou : .idle
                health = pending > 0 ? .needsYou : behind ? .behind : .onTrack
                trailing = behind || isSelected ? value : nil
                trailingIsMono = true
                if pending > 0 { spoken.append("needs you") }
                if onTrack != nil { spoken.append(behind ? "behind target" : "on track") }
            }
            trailingIsAlert = behind
            if steward.status != .paused, let value {
                spoken.append(target.map { "\(value) of \(StatusMapping.metric($0))" } ?? value)
            }
            accessibility = spoken.joined(separator: ", ")
        }
    }

    /// Needs you first, then behind target, then on track, then paused; by name within each.
    static func sorted(_ rows: [(StewardSummary, SidebarRow)]) -> [StewardSummary] {
        rows.sorted {
            $0.1.health != $1.1.health
                ? $0.1.health < $1.1.health
                : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
        }.map(\.0)
    }

    /// A metric value as the sidebar prints it: "0.84", or "12" for whole numbers of 10 or more.
    static func metric(_ value: Double) -> String {
        value.rounded() == value && abs(value) >= 10
            ? String(Int(value)) : String(format: "%.2f", value)
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
