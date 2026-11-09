import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func seriesAveragesReadingsPerDayAgainstTheCharterTarget() throws {
    let series = try #require(
        MetricSeries.build(
            events: PreviewFixtures.triage(now: now), steward: PreviewFixtures.steward))
    #expect(series.definition.name == "triaged_within_1h")
    #expect(series.definition.target == 0.95)
    #expect(series.points.map(\.count).reduce(0, +) == PreviewFixtures.metricValues.count)
    #expect(series.points.count >= 5)
    #expect(series.points == series.points.sorted { $0.day < $1.day })
    let latest = try #require(series.latest)
    #expect(abs(latest.value - 0.93) < 1e-9)
    #expect(series.meetsTarget == false)
    #expect(MetricText.title(series.definition) == "triaged_within_1h (ratio), target 0.95 or more")
}

@Test func summaryStatesLatestTrendAndTarget() {
    let definition = MetricDefinition(name: "m", unit: "", direction: .down, target: 5)
    let day = Date(timeIntervalSince1970: 0)
    var series = MetricSeries(definition: definition, points: [])
    #expect(MetricText.summary(series) == "m: no readings yet.")
    series.points = [
        MetricPoint(day: day, value: 6, count: 1),
        MetricPoint(day: day.addingTimeInterval(86_400), value: 4, count: 2),
    ]
    #expect(series.trend == .down)
    #expect(series.meetsTarget == true)
    #expect(MetricText.summary(series) == "m is 4.00, down from 6.00, meeting its target of 5.00.")
    series.points[1].value = 6
    #expect(MetricText.summary(series) == "m is 6.00, unchanged, short of its target of 5.00.")
}

@Test func readingsOfOtherMetricsAreIgnoredWhateverTheOrder() throws {
    var log = FeatureEventBuilder(start: now)
    log.add("metric.recorded", ["metric": "other", "value": 9])
    log.add("metric.recorded", ["metric": "kept", "value": 1])
    log.add("steward.created", ["charter": ["metric": ["name": "kept", "unit": "count"]]])
    let series = try #require(
        MetricSeries.build(events: log.events, steward: PreviewFixtures.steward))
    #expect(series.points.map(\.value) == [1])
    #expect(series.meetsTarget == nil)
    #expect(MetricSeries.build(events: log.events, steward: "st_none") == nil)
}

@Test func utcDaysStartAtMidnight() {
    let date = Date(timeIntervalSince1970: 86_400 * 3 + 5000)
    #expect(MetricSeries.utcDay(date) == Date(timeIntervalSince1970: 86_400 * 3))
}
