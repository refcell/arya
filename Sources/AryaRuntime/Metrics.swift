import AryaCore
import AryaLedger

/// `metric.recorded`: one measurement a live run reported in `run/result.measurements`.
///
/// The runtime writes it (actor: the steward, run: the run), so the payload lives here rather
/// than in `AryaEval`, which the runtime cannot import; eval reads it for metric series.
public struct MetricRecorded: EventPayload {
    public static let type = EventType.metricRecorded
    /// The metric name, as the charter's `metric` names it.
    public var metric: String
    /// The measured value.
    public var value: Double

    /// Creates a payload.
    public init(metric: String, value: Double) {
        self.metric = metric
        self.value = value
    }

    enum CodingKeys: String, CodingKey { case metric, value }
}

/// Event type names the runtime writes for metrics.
public enum MetricEventType {
    /// `metric.recorded`.
    public static let recorded = EventType.metricRecorded.rawValue
}
