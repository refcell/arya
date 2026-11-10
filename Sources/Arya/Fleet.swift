import AryaCore
import AryaRuntime
import Foundation

// The fleet sidebar in one call, and charter editing through the gated proposal path.

/// One steward as the fleet sidebar shows it.
public struct FleetItem: Sendable, Hashable, Codable {
    /// The newest live run.
    public struct LastRun: Sendable, Hashable, Codable {
        public var id: String
        public var title: String
        /// `running`, `finished`, or `failed`.
        public var status: String
        public var time: TimeText
    }

    public var steward: String
    public var name: String
    /// `active` or `paused`.
    public var state: String
    /// True once a person marked it ready for live triggers.
    public var ready: Bool
    public var metric: String
    public var unit: String
    public var current: Double?
    public var target: Double?
    /// `on_track`, `off_track`, `no_target`, or `no_data`.
    public var status: String
    public var pendingApprovals: Int
    /// Items in `needsYou()` for this steward (approvals, a failed run, a stale rehearsal).
    public var needsYou: Int
    public var lastRun: LastRun?
    /// When the next scheduled run starts; nil when it has no schedule, is paused, or a run
    /// is open.
    public var nextWake: TimeText?
}

/// A steward's charter as editable fields, with the version the edit starts from.
public struct CharterDraft: Sendable, Hashable, Codable {
    public var steward: String
    /// The live version; pass it back as `baseVersion` so a stale edit is refused.
    public var version: Int
    public var draft: StewardDraft
}

extension Workspace {
    /// Every active or paused steward, those needing a person first, then off track, then by
    /// name.
    public func fleet(timeZone: TimeZone = .current) async throws -> [FleetItem] {
        let now = ambient.now()
        func time(_ date: Date) -> TimeText { TimeText(date, now: now.date, timeZone: timeZone) }
        let needs = Dictionary(grouping: try await needsYou(timeZone: timeZone), by: \.steward)
        let pending = Dictionary(grouping: try await approvals(), by: \.steward)
        let runs = try await runBook()
        var items: [FleetItem] = []
        for record in try await stewardBook().all where record.status != .retired {
            let outcome = try await self.outcome(steward: record.id.rawValue)
            let last = runs.all.last {
                $0.steward == record.id && !$0.rehearsal && $0.parent == nil
            }
            let schedule = SchedulePlan.status(of: record, runs: runs, now: now)
            items.append(
                FleetItem(
                    steward: record.id.rawValue, name: record.charter.name,
                    state: record.status.rawValue, ready: record.ready, metric: outcome.metric,
                    unit: outcome.unit, current: outcome.current, target: outcome.target,
                    status: outcome.status.rawValue,
                    pendingApprovals: pending[record.id.rawValue]?.count ?? 0,
                    needsYou: needs[record.id.rawValue]?.count ?? 0,
                    lastRun: last.map {
                        let summary = RunSummary($0)
                        return .init(
                            id: summary.id, title: summary.title, status: summary.status.rawValue,
                            time: time(summary.endedAt ?? summary.startedAt))
                    },
                    nextWake: schedule.nextWake.map { time($0.date) }))
        }
        return items.sorted {
            if ($0.needsYou > 0) != ($1.needsYou > 0) { return $0.needsYou > 0 }
            if ($0.status == "off_track") != ($1.status == "off_track") {
                return $0.status == "off_track"
            }
            if ($0.state == "active") != ($1.state == "active") { return $0.state == "active" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The live charter as editable fields, for in-app editing.
    public func charterDraft(steward: String) async throws -> CharterDraft {
        let record = try await existing(steward)
        return CharterDraft(
            steward: record.id.rawValue, version: record.version,
            draft: StewardDraft(record.charter))
    }

    /// Proposes an edited charter: the draft is applied to the live charter (fields a draft
    /// does not hold are kept) and goes through the proposal and gate path; nothing changes
    /// until the proposal is checked and accepted. `baseVersion` (default: the live version)
    /// refuses an edit started from an older version.
    public func proposeCharter(
        steward: String, draft: StewardDraft, baseVersion: Int? = nil, title: String? = nil,
        reason: String? = nil, by person: String = "local"
    ) async throws -> ProposalSummary {
        let record = try await existing(steward)
        var draft = draft
        if draft.id == nil { draft.id = record.id.rawValue }
        let charter = try draft.applied(to: record.charter)
        guard charter != record.charter else {
            throw WorkspaceError.rejected("the draft changes nothing")
        }
        return try await proposeCharter(
            steward: steward, charter: try CanonicalJSON.encode(charter),
            baseVersion: baseVersion ?? record.version, title: title, reason: reason, by: person)
    }
}
