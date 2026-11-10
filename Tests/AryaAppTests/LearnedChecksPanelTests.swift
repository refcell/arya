import Testing

@testable import AryaApp

/// The checks header says at a glance whether the steward keeps what people taught it.
@Test func learnedChecksTally() {
    func checks(total: Int, scored: Int, passed: Int) -> FeatureLearnedChecks {
        FeatureLearnedChecks(
            version: 1, sentence: "", total: total, scored: scored, passed: passed, lines: [])
    }
    #expect(LearnedChecksText.tally(checks(total: 0, scored: 0, passed: 0)) == "none yet")
    #expect(LearnedChecksText.tally(checks(total: 3, scored: 0, passed: 0)) == "3 not rehearsed")
    #expect(LearnedChecksText.tally(checks(total: 9, scored: 9, passed: 8)) == "8/9 pass")
}
