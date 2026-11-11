import Arya
import AryaDesign
import CoreGraphics
import Foundation

/// How facade states appear as AryaDesign statuses.
enum StatusMapping {
    /// The one "behind target" rule for every count and red value: an active steward whose
    /// workspace `fleet()` status is `off_track`; without a fleet read, an active steward whose
    /// metric misses its target. Paused stewards are never behind.
    static func isBehind(_ steward: StewardSummary, fleet: [String: String], meetsTarget: Bool?)
        -> Bool
    {
        guard steward.status == .active else { return false }
        if let status = fleet[steward.id] { return status == "off_track" }
        return meetsTarget == false
    }

    static func status(of steward: StewardSummary, runs: [RunSummary]) -> AryaStatus {
        switch steward.status {
        case .paused: return .paused
        case .retired: return .idle
        case .active: return runs.contains { $0.status == .running } ? .running : .idle
        }
    }

    /// How a steward's sidebar row reads (STYLE.md Sidebar). The dot carries attention only:
    /// the live ring while a run goes, orange with pending approvals, else neutral (a ring
    /// when paused). The text carries
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
            onTrack: Bool?, isSelected: Bool, runningSteps: Int? = nil,
            fleet: [String: String] = [:]
        ) {
            let running = runningSteps != nil
            let value = latest.map(StatusMapping.metric)
            let behind = StatusMapping.isBehind(steward, fleet: fleet, meetsTarget: onTrack)
            var spoken = [steward.name]
            if steward.status == .paused {
                status = .paused
                health = .paused
                trailing = "paused"
                trailingIsMono = false
                spoken.append("paused")
            } else {
                // A run going right now takes the dot (the live ring) while it lasts; the
                // Needs you row and the sort still carry pending approvals.
                status = running ? .running : pending > 0 ? .needsYou : .idle
                if running { spoken.append("running") }
                health = pending > 0 ? .needsYou : behind ? .behind : .onTrack
                // While a run goes the trailing text is its step: "step 3".
                trailing =
                    runningSteps.map { "step \(max($0, 1))" }
                    ?? (behind || isSelected ? value : nil)
                trailingIsMono = true
                if pending > 0 { spoken.append("needs you") }
                if onTrack != nil { spoken.append(behind ? "behind target" : "on track") }
            }
            trailingIsAlert = behind && !running
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
    /// `dryRun` (workspace `runFacts`) reads the way the run thread does (app-views'
    /// `RunTitle.text`).
    static func threadTitle(of run: RunSummary, dryRun: Bool = false) -> String {
        let summary =
            run.summary?.split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        // Lists show a DRY RUN pill (`RunTitle.parts`); the sentence is for the run itself.
        if !summary.isEmpty { return RunTitle.parts(summary: summary, dryRun: dryRun).title }
        // The workspace title (the input's first line) next; never the trigger kind.
        let title = run.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Untitled run" : RunTitle.parts(summary: title, dryRun: dryRun).title
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
