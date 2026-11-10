import AryaCore

/// A backtest laid out for the Improve screen: two columns (current and proposed), metric rows
/// with deltas, and one row per case, regressed first. Every string is shown verbatim.
public struct BacktestView: Hashable, Sendable, Codable {
    /// Which way a metric moved for the steward.
    public enum Trend: String, Hashable, Sendable, Codable {
        case better, worse, same
    }

    /// One metric, side by side.
    public struct MetricRow: Hashable, Sendable, Codable {
        /// `Cases passed`, `Mean score`, `Leaks`, or the charter metric's name.
        public var label: String
        public var current: String
        public var proposed: String
        /// `+0.12`, `-1`, `0`; `n/a` when a side has no value.
        public var delta: String
        public var trend: Trend
    }

    /// One case, side by side.
    public struct CaseRow: Hashable, Sendable, Codable {
        public var caseID: String
        public var input: String
        /// What actually happened (the case's expected result), in words.
        public var expected: String
        /// What each variant would have done, in words.
        public var current: String
        public var proposed: String
        public var currentPassed: Bool
        public var proposedPassed: Bool
        public var change: CaseChange
        /// `Regressed`, `Improved`, or `Same`.
        public var changeLabel: String
        /// Score change, `+0.50`, `-1`, `0`.
        public var delta: String
        /// One line on the case, for example the field that changed.
        public var note: String
    }

    /// Column headers, for example `Live v1` and `Proposed v2`.
    public var currentLabel: String
    public var proposedLabel: String
    /// One line: `1 improved, 1 regressed; gate fails: case regressed`.
    public var headline: String
    public var gatePassed: Bool
    public var metrics: [MetricRow]
    public var improved: [String]
    public var regressed: [String]
    public var rows: [CaseRow]

    /// Lays out `comparison`. `metric` is the charter's outcome metric: when cases' results
    /// carry measurements of it, its mean per side becomes a metric row.
    public static func build(
        _ comparison: BacktestComparison, currentLabel: String, proposedLabel: String,
        metric: Metric? = nil
    ) -> BacktestView {
        let cases = comparison.cases
        let total = cases.count
        var metrics = [
            row(
                "Cases passed", Double(comparison.current.passed),
                Double(comparison.proposed.passed), higherIsBetter: true,
                text: { "\(Int($0))/\(total)" }, deltaText: whole),
            row(
                "Mean score", comparison.current.meanScore, comparison.proposed.meanScore,
                higherIsBetter: true, text: Backtests.format, deltaText: signed),
            row(
                "Leaks", Double(comparison.current.leaks), Double(comparison.proposed.leaks),
                higherIsBetter: false, text: { "\(Int($0))" }, deltaText: whole),
        ]
        if let metric {
            let old = mean(metric.name, cases.map(\.current))
            let new = mean(metric.name, cases.map(\.proposed))
            if old != nil || new != nil {
                metrics.append(
                    optionalRow(metric.name, old, new, higherIsBetter: metric.direction == .up))
            }
        }
        let order: [CaseChange: Int] = [.regressed: 0, .improved: 1, .unchanged: 2]
        let rows = cases.sorted {
            (order[$0.change] ?? 3, $0.caseID.rawValue) < (
                order[$1.change] ?? 3, $1.caseID.rawValue
            )
        }.map(caseRow)
        let up = cases.filter { $0.change == .improved }.map(\.caseID.rawValue)
        let down = cases.filter { $0.change == .regressed }.map(\.caseID.rawValue)
        let gate =
            comparison.verdict.passed
            ? "gate passes" : "gate fails: \(comparison.verdict.reason)"
        return BacktestView(
            currentLabel: currentLabel, proposedLabel: proposedLabel,
            headline: "\(up.count) improved, \(down.count) regressed; \(gate)",
            gatePassed: comparison.verdict.passed, metrics: metrics, improved: up,
            regressed: down, rows: rows)
    }

    static func caseRow(_ item: BacktestCase) -> CaseRow {
        let label: String
        switch item.change {
        case .regressed: label = "Regressed"
        case .improved: label = "Improved"
        case .unchanged: label = "Same"
        }
        let note: String
        switch item.change {
        case .regressed: note = item.proposed.diffText
        case .improved: note = item.current.diffText
        case .unchanged: note = item.proposed.passed ? "Both pass." : item.proposed.diffText
        }
        return CaseRow(
            caseID: item.caseID.rawValue, input: item.input, expected: item.expectedText,
            current: item.current.text, proposed: item.proposed.text,
            currentPassed: item.current.passed, proposedPassed: item.proposed.passed,
            change: item.change, changeLabel: label, delta: signed(item.delta), note: note)
    }

    static func row(
        _ label: String, _ old: Double, _ new: Double, higherIsBetter: Bool,
        text: (Double) -> String, deltaText: (Double) -> String
    ) -> MetricRow {
        MetricRow(
            label: label, current: text(old), proposed: text(new), delta: deltaText(new - old),
            trend: trend(new - old, higherIsBetter: higherIsBetter))
    }

    static func optionalRow(_ label: String, _ old: Double?, _ new: Double?, higherIsBetter: Bool)
        -> MetricRow
    {
        guard let old, let new else {
            return MetricRow(
                label: label, current: old.map(Backtests.format) ?? "n/a",
                proposed: new.map(Backtests.format) ?? "n/a", delta: "n/a", trend: .same)
        }
        return row(
            label, old, new, higherIsBetter: higherIsBetter, text: Backtests.format,
            deltaText: signed)
    }

    static func trend(_ delta: Double, higherIsBetter: Bool) -> Trend {
        let rounded = (delta * 100).rounded() / 100
        if rounded == 0 { return .same }
        return (rounded > 0) == higherIsBetter ? .better : .worse
    }

    /// `+0.12`, `-0.5`, `0`.
    static func signed(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == 0 { return "0" }
        return (rounded > 0 ? "+" : "") + Backtests.format(rounded)
    }

    /// `+1`, `-2`, `0`.
    static func whole(_ value: Double) -> String {
        let count = Int(value.rounded())
        return count > 0 ? "+\(count)" : "\(count)"
    }

    /// The mean of a metric's measurements across the variant's results, or nil without any.
    static func mean(_ metric: String, _ results: [CaseVariantResult]) -> Double? {
        let values = results.flatMap { result -> [Double] in
            (result.actual?["measurements"]?.arrayValue ?? []).compactMap { item in
                guard item["metric"]?.stringValue == metric else { return nil }
                switch item["value"] {
                case .double(let number)?: return number
                case .int(let number)?: return Double(number)
                default: return nil
                }
            }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
