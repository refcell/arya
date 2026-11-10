import Testing

@testable import AryaCLI

@Test func historyAndReviewUsageErrors() async {
    let cases: [([String], String)] = [
        (["history", "import", "st_triage"], "arya: give --file or --binding"),
        (
            ["history", "import", "st_triage", "--file", "a", "--limit", "0"],
            "arya: --limit must be a positive number"
        ),
        (
            ["review", "st_triage", "--case", "case-1"],
            "arya: give --verdict agree or skip with --case"
        ),
    ]
    for (line, message) in cases {
        let (status, capture) = await runCLI(line)
        #expect(status == .usage, "\(line)")
        #expect(capture.err.first == message, "\(line)")
    }
}

@Test func historyCommandsWithoutABackendAreNotAvailableYet() async {
    let (status, _) = await runCLI(["review", "st_triage"])
    #expect(status == .unavailable)
}
