import AryaDesign
import Charts
import SwiftUI

/// The steward's outcome metric over time against its target: one `ink` line, the target as a
/// dashed `inkFaint` rule, and the latest point as an `accent` dot with its value.
struct MetricChartView: View {
    @ObservedObject var store: FeatureStore
    var steward: String

    var body: some View {
        switch store.state {
        case .loading:
            Text("Loading the metric.").aryaText(AryaFont.caption, AryaColor.inkFaint)
        case .failed(let message):
            Text(message).aryaText(AryaFont.caption, AryaColor.negative)
        case .loaded(let events):
            if let series = MetricSeries.build(events: events, steward: steward) {
                MetricChart(series: series)
            } else {
                Text("This charter names no outcome metric.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        }
    }
}

/// The chart itself, for a ready series.
struct MetricChart: View {
    var series: MetricSeries

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text(MetricText.title(series.definition)).aryaText(AryaFont.caption, AryaColor.inkMuted)
            if series.points.isEmpty {
                Text("No readings yet. Runs report the metric in their results.")
                    .aryaText(AryaFont.body, AryaColor.inkMuted)
            } else {
                chart.frame(height: AryaSize.chartHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MetricText.summary(series))
    }

    private var chart: some View {
        Chart {
            ForEach(series.points) { point in
                LineMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                    .foregroundStyle(AryaColor.ink)
                    .lineStyle(StrokeStyle(lineWidth: AryaSize.chartLine))
            }
            if let target = series.definition.target {
                RuleMark(y: .value("Target", target))
                    .foregroundStyle(AryaColor.inkFaint)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: AryaSize.chartLine, dash: [AryaSpace.s1, AryaSpace.s1])
                    )
                    .annotation(position: .top, alignment: .leading) {
                        Text("target \(MetricText.value(target))")
                            .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    }
            }
            if let latest = series.latest {
                PointMark(
                    x: .value("Day", latest.day, unit: .day), y: .value("Value", latest.value)
                )
                .foregroundStyle(AryaColor.accent)
                .symbolSize(AryaSize.statusDot * AryaSize.statusDot)
                .annotation(position: .trailing) {
                    Text(MetricText.value(latest.value))
                        .aryaText(AryaFont.monoSmall, AryaColor.ink)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(AryaColor.inkMuted)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(AryaColor.rule)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(MetricText.value(number)).aryaText(
                            AryaFont.caption, AryaColor.inkMuted
                        )
                        .monospacedDigit()
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
    }
}
