import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

/// The M3.5 backtest fixture (7/8 against 7/8, case-0006 improved, case-0005 regressed) laid
/// out for the Improve screen.
@Test func backtestViewLaysOutTheFixture() async throws {
    let comparison = try await BacktestScenario.compare()
    let view = BacktestView.build(
        comparison, currentLabel: "Live v1", proposedLabel: "Proposed v2",
        metric: Metric(name: "routed_within_1h", unit: "ratio", direction: .up))
    #expect(view.headline == "1 improved, 1 regressed; gate fails: case regressed")
    #expect(!view.gatePassed)
    #expect(view.improved == ["case-0006"] && view.regressed == ["case-0005"])
    #expect(view.rows.first?.caseID == "case-0005")
    #expect(view.rows.first?.currentPassed == true && view.rows.first?.proposedPassed == false)
    #expect(view.rows.first?.delta.hasPrefix("-") == true)
    #expect(view.rows[1].caseID == "case-0006" && view.rows[1].delta.hasPrefix("+"))
    #expect(view.rows.dropFirst(2).allSatisfy { $0.changeLabel == "Same" })
    // The fixture's results measure the outcome metric, so it gets a row.
    #expect(
        view.metrics.map(\.label)
            == ["Cases passed", "Mean score", "Leaks", "routed_within_1h"])
    #expect(view.metrics[3].current != "n/a" && view.metrics[3].proposed != "n/a")
}

@Test func backtestViewNumbersAndTrends() {
    #expect(BacktestView.signed(0.123) == "+0.12")
    #expect(BacktestView.signed(-0.5) == "-0.5")
    #expect(BacktestView.signed(0.001) == "0")
    #expect(BacktestView.whole(2) == "+2" && BacktestView.whole(-1) == "-1")
    #expect(BacktestView.trend(1, higherIsBetter: false) == .worse)
    #expect(BacktestView.trend(-0.2, higherIsBetter: false) == .better)
    let missing = BacktestView.optionalRow("routed", 0.5, nil, higherIsBetter: true)
    #expect(missing.proposed == "n/a" && missing.delta == "n/a" && missing.trend == .same)
    let measured: JSONValue = [
        "measurements": [["metric": "routed", "value": 1], ["metric": "x", "value": 0]]
    ]
    let result = CaseVariantResult(
        runs: [], actual: measured, score: 1, passed: true, leak: false, notes: [], diff: [],
        text: "", diffText: "", scoreText: "")
    #expect(BacktestView.mean("routed", [result, result]) == 1)
    #expect(BacktestView.mean("other", [result]) == nil)
}
