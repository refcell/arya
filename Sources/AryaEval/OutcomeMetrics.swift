import AryaCore
import AryaRuntime

/// Summary of one metric's values in a window.
public struct MetricStat: Hashable, Sendable, Codable {
    public var count: Int
    public var sum: Double
    public var min: Double
    public var max: Double

    public var mean: Double { count == 0 ? 0 : sum / Double(count) }

    init(_ value: Double) {
        count = 1
        sum = value
        min = value
        max = value
    }

    mutating func add(_ value: Double) {
        count += 1
        sum += value
        min = Swift.min(min, value)
        max = Swift.max(max, value)
    }

    enum CodingKeys: String, CodingKey {
        case count, sum, min, max
    }
}

/// Action outcomes in a window.
public struct ActionCounts: Hashable, Sendable, Codable {
    public var executed = 0
    public var failed = 0
    public var rejected = 0

    enum CodingKeys: String, CodingKey {
        case executed, failed, rejected
    }
}

/// Approval decisions in a window.
public struct ApprovalCounts: Hashable, Sendable, Codable {
    public var granted = 0
    public var denied = 0
    public var expired = 0

    /// Granted over all decided approvals; `nil` when none were decided.
    public var rate: Double? {
        let total = granted + denied + expired
        return total == 0 ? nil : Double(granted) / Double(total)
    }

    enum CodingKeys: String, CodingKey {
        case granted, denied, expired
    }
}

/// One fixed window `[start, start + windowMillis)`.
public struct MetricWindow: Hashable, Sendable, Codable {
    public var start: Timestamp
    public var metrics: [String: MetricStat] = [:]
    public var actions = ActionCounts()
    public var approvals = ApprovalCounts()

    enum CodingKeys: String, CodingKey {
        case start, metrics, actions, approvals
    }
}

/// A steward's outcome series: contiguous windows, empty ones included, for the app chart.
public struct StewardSeries: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var windowMillis: Int64
    public var windows: [MetricWindow]

    /// The mean of `metric` per window, `nil` where it was not recorded.
    public func means(_ metric: String) -> [Double?] {
        windows.map { $0.metrics[metric]?.mean }
    }

    enum CodingKeys: String, CodingKey {
        case steward, windowMillis, windows
    }
}

/// Builds outcome series from ledger events: `metric.recorded` (`{"metric", "value"}`, the
/// shape of a `run/result` measurement), action outcomes, and approval decisions.
public enum OutcomeMetrics {
    public static let dayMillis: Int64 = 86_400_000

    /// Windows are aligned to multiples of `windowMillis` since the epoch (UTC days for the
    /// default). `range` limits and pads the series; by default it spans the steward's first to
    /// last counted event. Events outside the range and of other stewards are ignored.
    public static func series(
        _ events: [RuntimeEvent], steward: StewardID, windowMillis: Int64 = dayMillis,
        range: ClosedRange<Timestamp>? = nil
    ) -> StewardSeries {
        let width = Swift.max(1, windowMillis)
        let counted = events.filter { $0.draft.steward == steward && counts($0) }
        guard let span = range ?? span(of: counted) else {
            return StewardSeries(steward: steward, windowMillis: width, windows: [])
        }
        let first = floorDiv(span.lowerBound.millis, width)
        let last = floorDiv(span.upperBound.millis, width)
        var windows = (first...last).map { MetricWindow(start: Timestamp(millis: $0 * width)) }
        for event in counted where span.contains(event.at) {
            let index = Int(floorDiv(event.at.millis, width) - first)
            add(event, to: &windows[index])
        }
        return StewardSeries(steward: steward, windowMillis: width, windows: windows)
    }

    static func counts(_ event: RuntimeEvent) -> Bool {
        switch event.type {
        case "metric.recorded":
            return event.payload["metric"]?.stringValue != nil
                && event.payload["value"]?.doubleValue != nil
        case ActionEventType.executed, ActionEventType.failed, ActionEventType.rejected,
            ApprovalEventType.granted, ApprovalEventType.denied, ApprovalEventType.expired:
            return true
        default:
            return false
        }
    }

    static func add(_ event: RuntimeEvent, to window: inout MetricWindow) {
        switch event.type {
        case ActionEventType.executed: window.actions.executed += 1
        case ActionEventType.failed: window.actions.failed += 1
        case ActionEventType.rejected: window.actions.rejected += 1
        case ApprovalEventType.granted: window.approvals.granted += 1
        case ApprovalEventType.denied: window.approvals.denied += 1
        case ApprovalEventType.expired: window.approvals.expired += 1
        default:
            guard let name = event.payload["metric"]?.stringValue,
                let value = event.payload["value"]?.doubleValue
            else { return }
            if window.metrics[name] == nil {
                window.metrics[name] = MetricStat(value)
            } else {
                window.metrics[name]?.add(value)
            }
        }
    }

    static func span(of events: [RuntimeEvent]) -> ClosedRange<Timestamp>? {
        guard let low = events.map(\.at).min(), let high = events.map(\.at).max() else {
            return nil
        }
        return low...high
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
