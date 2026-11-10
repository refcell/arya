import AryaCore
import Foundation

/// The one evaluation window for a steward (CEO decision): the charter metric's period
/// (`metric.windowDays`, default the last 7 days), in UTC days. The outcome header's
/// `missed N of M`, the findings' streak and trend sentences, impact, and the metric trends
/// all use it and say so in their text.
public struct OutcomeWindow: Sendable, Hashable, Codable {
    public var steward: String
    public var days: Int
    /// True when the charter set the period; false for the 7-day default.
    public var fromCharter: Bool
    /// Start of the first day in the window (UTC midnight).
    public var start: Date
    public var end: Date
    /// `the last 7 days`, or `today` for a one-day window.
    public var text: String
    /// Days in the window with a reading of the primary metric.
    public var measured: Int
    /// Measured days that missed the target; 0 without a target.
    public var missed: Int
    /// One line, shown verbatim: `missed its target on 4 of the last 7 days`, or `4 of 6
    /// measured days in the last 7 days`; nil when nothing missed or there is no target.
    public var missedText: String?

    public static let defaultDays = 7
    static let day = 86_400
}

extension Workspace {
    /// The steward's evaluation window, with how many days in it missed the target.
    public func outcomeWindow(steward: String) async throws -> OutcomeWindow {
        let record = try await existing(steward)
        let metric = record.charter.metric
        let series = try await metrics(steward: steward, windowSeconds: OutcomeWindow.day)
        let bounds = Self.windowBounds(metric, now: now())
        let means = Dictionary(
            series.windows.map { ($0.start, $0.means[metric.name]) },
            uniquingKeysWith: { a, _ in a })
        let values = bounds.days.compactMap { means[$0] ?? nil }
        return Self.window(
            steward: record.id.rawValue, metric: metric, start: bounds.days[0], end: now(),
            values: values)
    }

    /// Each UTC day in the metric's window, oldest first, ending today.
    static func windowBounds(_ metric: Metric, now: Date) -> (count: Int, days: [Date]) {
        let count = max(1, metric.windowDays ?? OutcomeWindow.defaultDays)
        let day = Double(OutcomeWindow.day)
        let today = (now.timeIntervalSince1970 / day).rounded(.down) * day
        let days = (0..<count).reversed().map {
            Date(timeIntervalSince1970: today - Double($0) * day)
        }
        return (count, days)
    }

    static func window(
        steward: String, metric: Metric, start: Date, end: Date, values: [Double]
    ) -> OutcomeWindow {
        let days = max(1, metric.windowDays ?? OutcomeWindow.defaultDays)
        let text = days == 1 ? "today" : "the last \(days) days"
        let missed = values.filter { status(current: $0, metric: metric) == .offTrack }.count
        var line: String?
        if missed > 0 {
            line =
                values.count == days
                ? "missed its target on \(missed) of \(text)"
                : "missed its target on \(missed) of \(values.count) measured "
                    + "\(values.count == 1 ? "day" : "days") in \(text)"
        }
        return OutcomeWindow(
            steward: steward, days: days, fromCharter: metric.windowDays != nil, start: start,
            end: end, text: text, measured: values.count, missed: missed, missedText: line)
    }
}
