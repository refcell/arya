import AryaCore
import Foundation

/// One of a steward's metrics as the Overview METRICS panel shows it: the primary metric or
/// a guardrail metric, with its latest value, target, trend, and whether it meets the target.
public struct MetricStatus: Sendable, Hashable, Codable {
    public var name: String
    public var unit: String
    /// `up` or `down`: which way is better.
    public var direction: String
    public var target: Double?
    /// `primary` (the charter's `metric`) or `guardrail` (one of `guardrailMetrics`).
    public var role: String
    /// The newest window with a reading.
    public var current: Double?
    /// The window with a reading before that.
    public var previous: Double?
    /// The last `windows` windows, oldest first; nil values where nothing was recorded.
    public var trend: [OutcomeSummary.Point]
    public var status: OutcomeSummary.Status
    /// `improving`, `worsening`, `flat`, or `unknown` (fewer than two readings), against
    /// the metric's direction.
    public var movement: String
    /// One line, shown verbatim: `reply_minutes 42 minutes, target ≤ 60: on track,
    /// improving.`
    public var line: String
}

extension Workspace {
    /// Every metric the charter names, primary first and then its guardrail metrics, each with
    /// its latest value, target, trend over the last `windows` windows, and status.
    public func metricStatuses(
        steward: String, windows: Int = 14, windowSeconds: Int = 86_400
    ) async throws -> [MetricStatus] {
        let record = try await existing(steward)
        let series = try await metrics(steward: steward, windowSeconds: windowSeconds)
        let recent = series.windows.suffix(max(1, windows))
        let named =
            [(record.charter.metric, "primary")]
            + (record.charter.guardrailMetrics ?? []).map { ($0, "guardrail") }
        return named.map { metric, role in
            let trend = recent.map {
                OutcomeSummary.Point(start: $0.start, value: $0.means[metric.name])
            }
            let readings = trend.compactMap(\.value)
            let current = readings.last
            let previous = readings.count > 1 ? readings[readings.count - 2] : nil
            let status = Self.status(current: current, metric: metric)
            let movement = Self.movement(current: current, previous: previous, metric: metric)
            return MetricStatus(
                name: metric.name, unit: metric.unit, direction: metric.direction.rawValue,
                target: metric.target, role: role, current: current, previous: previous,
                trend: Array(trend), status: status, movement: movement,
                line: Self.metricLine(metric, current: current, status: status, movement))
        }
    }

    static func movement(current: Double?, previous: Double?, metric: Metric) -> String {
        guard let current, let previous else { return "unknown" }
        let scale = max(abs(previous), abs(current), 1e-9)
        if abs(current - previous) / scale < 0.01 { return "flat" }
        let better = metric.direction == .down ? current < previous : current > previous
        return better ? "improving" : "worsening"
    }

    static func metricLine(
        _ metric: Metric, current: Double?, status: OutcomeSummary.Status, _ movement: String
    ) -> String {
        let value = current.map { "\(number($0)) \(metric.unit)" } ?? "no readings"
        let target =
            metric.target.map {
                ", target \(metric.direction == .down ? "≤" : "≥") \(number($0))"
            } ?? ""
        let state: String
        switch status {
        case .onTrack: state = "on track"
        case .offTrack: state = "off track"
        case .noTarget: state = "no target"
        case .noData: state = "no data"
        }
        let moved = movement == "unknown" ? "" : ", \(movement)"
        return "\(metric.name) \(value)\(target): \(state)\(moved)."
    }

}
