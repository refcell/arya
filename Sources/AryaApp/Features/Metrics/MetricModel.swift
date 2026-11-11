import Foundation
import SwiftUI

/// A charter's outcome metric definition.
struct MetricDefinition: Hashable, Sendable {
    enum Direction: String, Hashable, Sendable {
        case up, down
    }

    var name: String
    var unit: String
    var direction: Direction
    var target: Double?
}

/// One point of the series: the mean of a UTC day's readings.
struct MetricPoint: Hashable, Sendable, Identifiable {
    var day: Date
    var value: Double
    var count: Int

    var id: Date { day }
}

/// A steward's outcome metric over time against its target.
struct MetricSeries: Hashable, Sendable {
    enum Trend: String, Hashable, Sendable {
        case up, down, flat
    }

    var definition: MetricDefinition
    var points: [MetricPoint]

    var latest: MetricPoint? { points.last }

    /// The latest day compared with the one before it.
    var trend: Trend? {
        guard points.count >= 2 else { return nil }
        let delta = points[points.count - 1].value - points[points.count - 2].value
        if abs(delta) < 1e-9 { return .flat }
        return delta > 0 ? .up : .down
    }

    /// Whether the latest value meets the target in the metric's direction.
    var meetsTarget: Bool? {
        guard let target = definition.target, let latest else { return nil }
        return definition.direction == .up ? latest.value >= target : latest.value <= target
    }

    /// The steward's metric from its latest charter and every `metric.recorded` for it, as
    /// per-UTC-day means (the windows AryaEval's outcome series uses). Nil without a charter
    /// metric.
    static func build(events: [FeatureEvent], steward: String) -> MetricSeries? {
        var definition: MetricDefinition?
        var days: [String: [Date: (sum: Double, count: Int)]] = [:]
        for event in events where event.steward == steward {
            switch event.type {
            case "steward.created", "steward.charter.updated":
                if let metric = event.payload["charter"]?["metric"] {
                    definition = parse(metric) ?? definition
                }
            case "metric.recorded":
                guard let name = event.payload["metric"]?.string,
                    let value = event.payload["value"]?.number
                else { continue }
                let day = utcDay(event.at)
                days[name, default: [:]][day, default: (0, 0)].sum += value
                days[name, default: [:]][day, default: (0, 0)].count += 1
            default: continue
            }
        }
        guard let definition else { return nil }
        let named = days[definition.name] ?? [:]
        let points = named.keys.sorted().compactMap { day -> MetricPoint? in
            guard let bucket = named[day] else { return nil }
            return MetricPoint(
                day: day, value: bucket.sum / Double(bucket.count), count: bucket.count)
        }
        return MetricSeries(definition: definition, points: points)
    }

    private static func parse(_ json: FeatureJSON) -> MetricDefinition? {
        guard let name = json["name"]?.string else { return nil }
        return MetricDefinition(
            name: name, unit: json["unit"]?.string ?? "",
            direction: MetricDefinition.Direction(rawValue: json["direction"]?.string ?? "up")
                ?? .up,
            target: json["target"]?.number)
    }

    static func utcDay(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 86_400).rounded(.down) * 86_400)
    }
}

/// Text for the metric chart, kept apart from layout so it can be tested.
enum MetricText {
    static func value(_ value: Double) -> String { String(format: "%.2f", value) }

    /// A metric's name on every screen, the one formatter: charters carry no separate label,
    /// so the key reads in words ("first_reply_within_1d" reads "first reply within 1d").
    static func name(_ key: String) -> String { key.replacingOccurrences(of: "_", with: " ") }

    /// The key for words a person typed: "routed within 1h" is stored "routed_within_1h".
    static func key(_ words: String) -> String { words.replacingOccurrences(of: " ", with: "_") }

    /// A text field's binding that shows a metric key in words and stores the key.
    static func words(_ key: Binding<String>) -> Binding<String> {
        Binding(get: { name(key.wrappedValue) }, set: { key.wrappedValue = Self.key($0) })
    }

    /// Every metric key in a sentence as words ("routed_within_1h missed its target…" reads
    /// "routed within 1h missed its target…"), for workspace lines shown verbatim otherwise.
    static func sentence(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = text
        for match in snake.matches(in: text, range: range).reversed() {
            guard let found = Range(match.range, in: out) else { continue }
            out.replaceSubrange(found, with: name(String(out[found])))
        }
        return out
    }

    private static let snake = try! NSRegularExpression(
        pattern: #"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b"#)

    /// The one way a reading shows against its target (header, METRICS, portfolio, inspector):
    /// "0.84", "12" for whole numbers of 10 or more. When the workspace says off target but the
    /// reading rounds to the target, it gains decimals until the gap shows ("0.897" against
    /// "0.90"), so the status never looks wrong.
    static func reading(_ value: Double, target: Double?, offTarget: Bool) -> String {
        var digits = 2
        if offTarget, let target, value != target {
            func ties(_ digits: Int) -> Bool {
                let scale = pow(10, Double(digits))
                return abs((value * scale).rounded() / scale - target) < 1e-9
            }
            while digits < 4, ties(digits) { digits += 1 }
        }
        return short(value, digits)
    }

    /// A target as `reading` prints its peers: "0.90", "12".
    static func target(_ target: Double) -> String { short(target, 2) }

    /// "0.897 / 0.90", "0.84", or "— / 0.90" before the first reading.
    static func figure(_ value: Double?, target: Double?, offTarget: Bool) -> String {
        let shown = value.map { reading($0, target: target, offTarget: offTarget) } ?? "—"
        return shown + (target.map { " / \(Self.target($0))" } ?? "")
    }

    private static func short(_ value: Double, _ digits: Int) -> String {
        value.rounded() == value && abs(value) >= 10
            ? String(Int(value)) : String(format: "%.\(digits)f", value)
    }

    /// "triaged_within_1h (ratio), target 0.95 or more".
    static func title(_ definition: MetricDefinition) -> String {
        var text = name(definition.name)
        if !definition.unit.isEmpty { text += " (\(definition.unit))" }
        if let target = definition.target {
            text +=
                ", target \(value(target)) or " + (definition.direction == .up ? "more" : "less")
        }
        return text
    }

    /// The chart's accessibility label: latest value, trend, and target status.
    static func summary(_ series: MetricSeries) -> String {
        guard let latest = series.latest else {
            return "\(name(series.definition.name)): no readings yet."
        }
        var text = "\(name(series.definition.name)) is \(value(latest.value))"
        if let trend = series.trend, series.points.count >= 2 {
            let previous = value(series.points[series.points.count - 2].value)
            switch trend {
            case .up: text += ", up from \(previous)"
            case .down: text += ", down from \(previous)"
            case .flat: text += ", unchanged"
            }
        }
        if let meets = series.meetsTarget, let target = series.definition.target {
            text +=
                meets
                ? ", meeting its target of \(value(target))"
                : ", short of its target of \(value(target))"
        }
        return text + "."
    }
}
