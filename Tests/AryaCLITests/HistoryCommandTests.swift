import Arya
import Foundation
import Testing

@testable import AryaCLI

@Test func historyAndReviewUsageErrors() async {
    let cases: [([String], String)] = [
        (["history", "import", "st_triage"], "arya: give --file or --from"),
        (
            ["history", "import", "st_triage", "--from", "a", "--binding", "b"],
            "arya: give --from or --binding, not both"
        ),
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

@Test func learnedChecksText() throws {
    let json = """
        {"steward":"st_triage","version":2,"total":1,"scored":1,"passed":0,"added":[],
         "removed":[],"sentence":"Checks v2: passes 0 of 1.","results":[{"passed":false,
         "found":"choice: bug","result":"Breaks “Features” on c2: choice: bug, not feature.",
         "check":{"id":"c2/x","case":"c2","origin":"corrected",
         "by":"local","text":"Feature requests are features.",
         "check":{"kind":"equals","path":"decisions.choice","value":"feature","weight":1}}}]}
        """
    let view = try JSONDecoder().decode(LearnedChecksSummary.self, from: Data(json.utf8))
    #expect(
        HistoryText.checks(view) == [
            "Checks v2: passes 0 of 1.",
            "  FAIL  Breaks “Features” on c2: choice: bug, not feature.",
        ])
}

/// Approvers read a proposal's title and why: both must reach the backend, not stop at a
/// protocol-extension default.
@Test func proposeTitleAndReasonReachTheBackend() async {
    let backend = FakeBackend()
    let (status, capture) = await runCLI(
        ["propose", "st_x", "--charter", "v2.json", "--title", "Relax it", "--reason", "Late"],
        backend: backend)
    #expect(status == .ok, "\(capture.errText)")
    #expect(backend.calls == ["propose st_x v2.json title=Relax it reason=Late"])
}
