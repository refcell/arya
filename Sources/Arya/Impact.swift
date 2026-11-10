import AryaCore
import AryaMemory
import AryaRuntime
import Foundation

/// Which actions moved a steward's metric. Each change between two metric readings is credited
/// to the action kinds executed in that window, by each kind's share of the window's actions.
/// Kinds that ran in exactly the same windows cannot be told apart, so they share one row.
public struct ImpactSummary: Sendable, Hashable, Codable {
    /// One kind, or kinds that always ran together.
    public struct Row: Sendable, Hashable, Codable, Identifiable {
        public var kinds: [String]
        /// "label", or "label + route" for kinds that always ran together.
        public var label: String
        /// Metric change credited to the row, in metric units (signed as the metric moved).
        public var credit: Double
        /// True when the credit moved the metric the good way.
        public var helped: Bool
        public var actions: Int
        /// Windows (reading to reading) the row ran in.
        public var windows: Int
        /// 0...1: more windows, windows that agree in direction, and follow-up checks that
        /// resolved all raise it.
        public var confidence: Double
        /// `high`, `medium`, or `low`.
        public var confidenceLevel: String
        /// Resolved among settled follow-up checks of these kinds, when any settled.
        public var successRate: Double?
        /// "label: +0.040 over 12 actions in 5 of 7 windows, medium confidence".
        public var line: String
        public var id: String { label }
    }

    public var steward: String
    public var metric: String
    /// `up` or `down`: which way is good.
    public var direction: String
    /// Readings of the metric.
    public var readings: Int
    /// Separable rows, most helpful first; empty when the actions cannot be told apart.
    public var rows: [Row]
    /// The whole change over windows with actions, and the actions in them.
    public var total: Double
    public var actions: Int
    /// Kinds that always ran together when no row could be split out.
    public var together: [String]
    /// One line for the section: the honest summary when nothing splits.
    public var summary: String
}

/// A line for the Overview's findings: a steward's own finding, or a change the ledger shows.
public struct OverviewFinding: Sendable, Hashable, Codable, Identifiable {
    /// `problem` or `opportunity` (raised by the steward), `attention`, `negative`,
    /// `positive`, or `info` (read from the ledger).
    public var kind: String
    public var text: String
    /// The runtime finding (`<run>/<finding>`), for resolving it.
    public var finding: String?
    /// What a view opens: `approval`, `run`, `proposal`, `finding`, or nil.
    public var link: NeedsYouItem.Link?
    public var id: String { finding ?? text }
}

extension Workspace {
    /// Which action kinds moved `steward`'s metric, with attribution and confidence; nil when
    /// the charter's metric has fewer than two readings or no window had actions.
    public func impact(steward: String, limit: Int = 5) async throws -> ImpactSummary? {
        let record = try await existing(steward)
        let metric = record.charter.metric
        let events = try facadeState().bySteward[record.id] ?? []
        var kinds: [String: String] = [:]
        var executed: [String] = []
        var windows: [(delta: Double, counts: [String: Int])] = []
        var last: Double?
        var readings = 0
        for event in events {
            let run = event.draft.run?.rawValue ?? ""
            switch event.type {
            case ActionEventType.proposed:
                if let id = event.payload["action"]?["id"]?.stringValue,
                    let kind = event.payload["action"]?["kind"]?.stringValue
                {
                    kinds[run + "/" + id] = kind
                }
            case ActionEventType.executed:
                guard event.payload["dryRun"] != true,
                    let id = event.payload["action"]?.stringValue, let kind = kinds[run + "/" + id]
                else { continue }
                executed.append(kind)
            case MetricEventType.recorded:
                guard event.payload["metric"]?.stringValue == metric.name,
                    let value = event.payload["value"]?.doubleValue, value.isFinite
                else { continue }
                readings += 1
                if let last, !executed.isEmpty {
                    windows.append(
                        (value - last, Dictionary(executed.map { ($0, 1) }, uniquingKeysWith: +)))
                }
                last = value
                executed = []
            default:
                continue
            }
        }
        guard readings >= 2, !windows.isEmpty else { return nil }
        let rates = Dictionary(
            try await effectiveness(steward: steward).map { ($0.kind, $0) },
            uniquingKeysWith: { a, _ in a })
        return Self.attribute(
            windows, steward: steward, metric: metric, readings: readings, rates: rates,
            limit: limit)
    }

    static func attribute(
        _ windows: [(delta: Double, counts: [String: Int])], steward: String, metric: Metric,
        readings: Int, rates: [String: EffectSummary], limit: Int
    ) -> ImpactSummary {
        var signature: [String: [Int]] = [:]
        for (index, window) in windows.enumerated() {
            for kind in window.counts.keys { signature[kind, default: []].append(index) }
        }
        let groups = Dictionary(grouping: signature.keys) { signature[$0] ?? [] }
            .map { $0.value.sorted() }.sorted { $0[0] < $1[0] }
        let total = windows.reduce(0) { $0 + $1.delta }
        let actions = windows.reduce(0) { $0 + $1.counts.values.reduce(0, +) }
        let good: (Double) -> Double = { metric.direction == .down ? -$0 : $0 }
        var rows: [ImpactSummary.Row] = []
        if groups.count > 1 {
            rows = groups.map { group in
                var credit = 0.0
                var count = 0
                var shares: [Double] = []
                for window in windows {
                    let mine = group.reduce(0) { $0 + (window.counts[$1] ?? 0) }
                    guard mine > 0 else { continue }
                    let share =
                        window.delta * Double(mine) / Double(window.counts.values.reduce(0, +))
                    credit += share
                    count += mine
                    shares.append(share)
                }
                let agree = shares.filter { abs($0) < 1e-9 || ($0 >= 0) == (credit >= 0) }.count
                let consistency = shares.isEmpty ? 0 : Double(agree) / Double(shares.count)
                let support = min(1, Double(shares.count) / 6)
                let settled = group.compactMap { rates[$0] }.filter { $0.successRate != nil }
                let rate: Double? =
                    settled.isEmpty
                    ? nil
                    : Double(settled.reduce(0) { $0 + $1.resolved })
                        / Double(max(1, settled.reduce(0) { $0 + $1.resolved + $1.reopened }))
                var confidence = support * consistency
                if let rate { confidence = 0.8 * confidence + 0.2 * rate }
                let level = confidence >= 0.66 ? "high" : confidence >= 0.33 ? "medium" : "low"
                let label = group.joined(separator: " + ")
                let noun = count == 1 ? "action" : "actions"
                return ImpactSummary.Row(
                    kinds: group, label: label, credit: credit, helped: good(credit) >= 0,
                    actions: count, windows: shares.count, confidence: confidence,
                    confidenceLevel: level, successRate: rate,
                    line: "\(label): \(signed(credit)) over \(count) \(noun) in "
                        + "\(shares.count) of \(windows.count) windows, \(level) confidence")
            }
            .sorted { good($0.credit) > good($1.credit) }
        }
        let together = groups.count == 1 ? groups[0] : []
        var summary = "\(metric.name) \(signed(total)) over \(actions) "
        summary += actions == 1 ? "action" : "actions"
        if together.count > 1 {
            summary +=
                "; \(together.joined(separator: " and ")) always ran together, so the change "
                + "is not split by action."
        } else if let best = rows.first {
            summary += "; most of it from \(best.label) (\(best.confidenceLevel) confidence)."
        } else {
            summary += "."
        }
        return ImpactSummary(
            steward: steward, metric: metric.name, direction: metric.direction.rawValue,
            readings: readings, rows: Array(rows.prefix(max(0, limit))), total: total,
            actions: actions, together: together, summary: summary)
    }

    /// The Overview's findings for `steward`: its open findings first, then what the ledger
    /// shows (target misses, the recent trend, approvals waiting, failed runs this week,
    /// routines it proposed, proposed changes that regressed in rehearsal).
    public func overviewFindings(steward: String, timeZone: TimeZone = .current) async throws
        -> [OverviewFinding]
    {
        let record = try await existing(steward)
        let now = now()
        var out = try await findings(steward: steward).map {
            OverviewFinding(
                kind: $0.kind, text: $0.title, finding: $0.id,
                link: .init(kind: "finding", id: $0.id))
        }
        let outcome = try await self.outcome(steward: steward)
        let measured = outcome.trend.compactMap(\.value)
        let metric = record.charter.metric
        let missed = measured.filter {
            Self.status(current: $0, metric: metric) == .offTrack
        }.count
        if missed > 0 {
            out.append(
                OverviewFinding(
                    kind: "negative",
                    text: "\(metric.name) missed its target on \(missed) of the last "
                        + "\(measured.count) measured days"))
        }
        let recent = measured.suffix(7)
        if let first = recent.first, let last = recent.last, recent.count >= 2,
            abs(last - first) >= 0.01
        {
            let better = metric.direction == .down ? last < first : last > first
            out.append(
                OverviewFinding(
                    kind: better ? "positive" : "negative",
                    text: "\(metric.name) \(last > first ? "rose" : "fell") from "
                        + "\(Self.number(first)) to \(Self.number(last)) over those days"))
        }
        let waiting = try await approvals().filter { $0.steward == steward }
        if let oldest = waiting.min(by: { $0.requestedAt < $1.requestedAt }) {
            let count = waiting.count
            let since = TimeText(oldest.requestedAt, now: now, timeZone: timeZone).relative
            out.append(
                OverviewFinding(
                    kind: "attention",
                    text: "\(count) \(count == 1 ? "approval waits" : "approvals wait") on you, "
                        + "the oldest since \(since)",
                    link: .init(kind: "approval", id: oldest.id)))
        }
        let week = now.addingTimeInterval(-7 * 86_400)
        let failed = try await runs(steward: steward).filter {
            $0.status == .failed && ($0.endedAt ?? $0.startedAt) >= week
        }
        if let newest = failed.first {
            out.append(
                OverviewFinding(
                    kind: "negative",
                    text: "\(failed.count) \(failed.count == 1 ? "run" : "runs") failed this week",
                    link: .init(kind: "run", id: newest.id)))
        }
        for event in try facadeState().bySteward[record.id] ?? []
        where event.type == RoutineEventType.proposed {
            if let reason = event.payload["reason"]?.stringValue, !reason.isEmpty {
                out.append(OverviewFinding(kind: "info", text: reason))
            }
        }
        for proposal in try await proposals(steward: steward)
        where ["open", "failed"].contains(proposal.status) {
            guard let worse = proposal.verdict?.regressions, !worse.isEmpty else { continue }
            out.append(
                OverviewFinding(
                    kind: "attention",
                    text: "A proposed change made \(worse.joined(separator: ", ")) worse in "
                        + "rehearsal",
                    link: .init(kind: "proposal", id: proposal.id)))
        }
        return out
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

private func signed(_ value: Double) -> String { String(format: "%+.3f", value) }
