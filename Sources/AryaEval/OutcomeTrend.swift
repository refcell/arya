import AryaCore
import AryaRuntime

/// Sparkline data for the outcome screen: the steward's metric over a fixed number of windows
/// ending at a caller-given time, so the same ledger and `end` always give the same points.
public struct OutcomeTrend: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var metric: String
    public var unit: String
    public var direction: Metric.Direction
    public var target: Double?
    public var windowMillis: Int64
    /// Start of the first window; window `i` starts at `start + i * windowMillis`.
    public var start: Timestamp
    /// The metric's mean per window, `nil` where nothing was recorded.
    public var points: [Double?]
    /// Approval rate (granted over decided) per window, `nil` where nothing was decided.
    public var approvalRates: [Double?]
    /// Actions executed per window.
    public var executed: [Int]
    /// The last recorded point.
    public var latest: Double?
    /// `latest` minus the first recorded point; `nil` with fewer than two points.
    public var change: Double?
    /// Whether `change` moves in the metric's direction; `nil` when there is no change to judge.
    public var improving: Bool?
}

/// Builds `OutcomeTrend`s from the ledger and the live charter's metric.
public struct OutcomeTrends: Sendable {
    public var sink: any EventSink

    public init(sink: any EventSink) {
        self.sink = sink
    }

    /// `windows` windows of `windowMillis` (UTC days by default), the last containing `end`.
    public func trend(
        _ steward: StewardID, end: Timestamp, windows: Int = 14,
        windowMillis: Int64 = OutcomeMetrics.dayMillis
    ) async throws -> OutcomeTrend {
        let events = try await sink.events(from: 1)
        guard let live = try StewardBook(events).records[steward] else {
            throw StewardError.notFound(steward)
        }
        return OutcomeTrend.build(
            events, steward: steward, metric: live.charter.metric, end: end, windows: windows,
            windowMillis: windowMillis)
    }
}

extension OutcomeTrend {
    /// Pure: the same events and arguments give the same trend.
    public static func build(
        _ events: [RuntimeEvent], steward: StewardID, metric: Metric, end: Timestamp,
        windows: Int = 14, windowMillis: Int64 = OutcomeMetrics.dayMillis
    ) -> OutcomeTrend {
        let width = max(1, windowMillis)
        let count = Int64(max(1, windows))
        let first = (OutcomeMetrics.floorDiv(end.millis, width) - count + 1) * width
        let start = Timestamp(millis: first)
        let series = OutcomeMetrics.series(
            events, steward: steward, windowMillis: width, range: start...end)
        let points = series.means(metric.name)
        let recorded = points.compactMap { $0 }
        let change = recorded.count < 2 ? nil : recorded[recorded.count - 1] - recorded[0]
        let improving = change.flatMap { change -> Bool? in
            guard change != 0 else { return nil }
            return metric.direction == .up ? change > 0 : change < 0
        }
        return OutcomeTrend(
            steward: steward, metric: metric.name, unit: metric.unit,
            direction: metric.direction, target: metric.target, windowMillis: width,
            start: start, points: points, approvalRates: series.windows.map(\.approvals.rate),
            executed: series.windows.map(\.actions.executed), latest: recorded.last,
            change: change, improving: improving)
    }
}
