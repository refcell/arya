import AryaCore
import AryaEval
import Foundation

// Read models for the improvement loop. Plain values, so the CLI and the app need no lower
// module.

/// One imported casebook version.
public struct CasebookSummary: Sendable, Hashable, Codable {
    /// Casebook name, for example `triage`.
    public var name: String
    /// Steward it was imported for.
    public var steward: String
    /// Content hash of the normalized casebook.
    public var version: String
    /// Number of cases.
    public var cases: Int
    /// The version this one corrects, if it came from a correction.
    public var correctedFrom: String?
    /// When it was recorded.
    public var importedAt: Date
}

/// One case of a rehearsal.
public struct RehearsedCaseSummary: Sendable, Hashable, Codable {
    /// Case id.
    public var id: String
    /// True when every sample passed.
    public var passed: Bool
    /// Mean score over samples, 0 to 1.
    public var score: Double
    /// True when a tool read had no recorded answer.
    public var leak: Bool
    /// Scorer notes from the first failing sample (failed fields, `leak`, run errors).
    public var notes: [String]
}

/// A finished rehearsal.
public struct RehearsalSummary: Sendable, Hashable, Codable {
    /// Rehearsal id (`reh_…`).
    public var id: String
    /// Steward id.
    public var steward: String
    /// Charter version rehearsed (0 for a proposal's candidate).
    public var charterVersion: Int
    /// Casebook name and version.
    public var casebook: String
    public var casebookVersion: String
    /// Cases that passed in every sample.
    public var passed: Int
    /// Cases rehearsed.
    public var total: Int
    /// Mean score over every case, 0 to 1.
    public var meanScore: Double
    /// Ids of the cases that did not pass, in case order.
    public var failed: [String]
    /// Every case, in case order.
    public var cases: [RehearsedCaseSummary]

    init(_ result: RehearsalResult, casebookName: String) {
        id = result.id?.rawValue ?? ""
        steward = result.request.steward.rawValue
        charterVersion = result.request.charterVersion
        casebook = casebookName
        casebookVersion = result.request.casebookVersion
        cases = result.outcomes.map { outcome in
            let values = outcome.samples.map(\.value)
            return RehearsedCaseSummary(
                id: outcome.caseID.rawValue,
                passed: !outcome.leak && !outcome.samples.isEmpty
                    && outcome.samples.allSatisfy(\.passed),
                score: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count),
                leak: outcome.leak,
                notes: outcome.samples.first { !$0.passed }?.notes ?? [])
        }
        passed = cases.filter(\.passed).count
        total = cases.count
        meanScore = GateRule.mean(result)
        failed = cases.filter { !$0.passed }.map(\.id)
    }

    init(_ result: RehearsalResult, casebook: Casebook) {
        self.init(result, casebookName: casebook.name)
    }
}

/// The result of a correction.
public struct CorrectionSummary: Sendable, Hashable, Codable {
    public var steward: String
    /// Corrected case id.
    public var caseID: String
    /// The memory note the correction became.
    public var note: String
    /// The casebook version to rehearse next: the corrected one when the expected result
    /// changed, else the one corrected.
    public var casebook: String
}

/// A steward's outcome series in fixed windows.
public struct MetricSeriesSummary: Sendable, Hashable, Codable {
    /// One window.
    public struct Window: Sendable, Hashable, Codable {
        /// Window start.
        public var start: Date
        /// Mean of each recorded metric in the window, by metric name.
        public var means: [String: Double]
        /// Number of values of each metric in the window.
        public var counts: [String: Int]
        /// Action outcomes.
        public var executed: Int
        public var failed: Int
        public var rejected: Int
        /// Approval decisions.
        public var granted: Int
        public var denied: Int
        public var expired: Int
        /// Granted over decided; `nil` when nothing was decided.
        public var approvalRate: Double?
    }

    public var steward: String
    /// The charter's success metric.
    public var metric: String
    public var unit: String
    /// `up` or `down`: which way is better.
    public var direction: String
    public var target: Double?
    /// Window width in seconds.
    public var windowSeconds: Int
    /// Windows, oldest first, empty ones included.
    public var windows: [Window]

    init(_ series: StewardSeries, metric: Metric) {
        steward = series.steward.rawValue
        self.metric = metric.name
        unit = metric.unit
        direction = metric.direction.rawValue
        target = metric.target
        windowSeconds = Int(series.windowMillis / 1000)
        windows = series.windows.map { window in
            Window(
                start: window.start.date, means: window.metrics.mapValues(\.mean),
                counts: window.metrics.mapValues(\.count), executed: window.actions.executed,
                failed: window.actions.failed, rejected: window.actions.rejected,
                granted: window.approvals.granted, denied: window.approvals.denied,
                expired: window.approvals.expired, approvalRate: window.approvals.rate)
        }
    }
}
