import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

private let learnSteward = StewardID(unchecked: "st_learn")

private let learnCharter = Charter(
    id: learnSteward, name: "Learning triage", outcome: "Every issue is triaged.",
    metric: Metric(name: "triaged", unit: "ratio", direction: .up), adapter: "fake")

/// A person's correction becomes a check in their words that the steward keeps being scored
/// on; an agreement keeps the case's expectation; a later skip drops it in a new version.
@Test func correctionsAndAgreementsBecomeVersionedChecks() async throws {
    let ambient = Ambient.fixed(stepMillis: 2, seed: 93)
    let sink = MemoryEventSink(ambient: ambient)
    let blobs = MemoryBlobs()
    let casebooks = StoredCasebooks(sink: sink, blobs: blobs)
    let line = { (id: String, choice: String) in
        #"{"v":1,"id":"\#(id)","input":{"text":"\#(id)"},"#
            + #""expected":{"decisions":[{"choice":"\#(choice)"}]}}"#
    }
    let data = [line("c1", "bug"), line("c2", "bug"), line("c3", "bug")].joined(separator: "\n")
    let (book, _) = try await CasebookImporter(blobs: blobs, sink: sink)
        .importCasebook(name: "triage", data: Data(data.utf8), steward: learnSteward)
    let checks = LearnedChecks(sink: sink, casebooks: casebooks)
    #expect(try await checks.view(steward: learnSteward) == nil)
    // Nothing taught yet: building records nothing.
    #expect(try await checks.build(steward: learnSteward).checks.isEmpty)
    #expect(try await checks.view(steward: learnSteward) == nil)

    let rehearser = CasebookRehearser(
        runner: ScriptedRunner(
            answers: [
                "c1": ["decisions": [["choice": "bug"]]],
                "c2": ["decisions": [["choice": "bug"]]],
                "c3": ["decisions": [["choice": "bug"]]],
            ]),
        casebooks: casebooks, sink: sink, ambient: ambient,
        scorer: ExactScorer(fields: ["decisions.choice"]))
    _ = try await rehearser.rehearse(
        RehearsalRequest(steward: learnSteward, charterVersion: 1, casebookVersion: book.version),
        charter: learnCharter)
    let queue = ReviewQueue(sink: sink, casebooks: casebooks)
    try await queue.record(
        .agreed, caseID: CaseID(rawValue: "c1")!, casebook: book, steward: learnSteward,
        person: "person:alex")
    try await queue.record(
        .skipped, caseID: CaseID(rawValue: "c3")!, casebook: book, steward: learnSteward,
        person: "person:alex")
    _ = try await Corrector(sink: sink, blobs: blobs, ambient: ambient).correct(
        CaseCorrection(
            caseID: CaseID(rawValue: "c2")!, text: "Feature requests are features.",
            expected: ["decisions": [["choice": "feature"]]]),
        in: book, steward: learnSteward, person: "person:sam")

    let first = try await checks.build(steward: learnSteward, actor: .person("person:alex"))
    #expect(first.version == 1)
    #expect(first.checks.map(\.id) == ["c1/decisions.choice=bug", "c2/decisions.choice=feature"])
    #expect(first.checks.map(\.text) == ["Chooses bug (agreed)", "Feature requests are features."])
    #expect(first.checks.map(\.origin) == [.agreed, .corrected])
    #expect(first.checks.map(\.by) == ["person:alex", "person:sam"])

    // The rehearsal answered bug on c2: the correction's check fails and leads.
    let view = try #require(try await checks.view(steward: learnSteward))
    #expect(view.results.map(\.check.caseID.rawValue) == ["c2", "c1"])
    #expect(view.results.map(\.passed) == [false, true])
    #expect(view.results[0].found == "choice: bug")
    #expect(
        view.sentence
            == "Checks v1: passes 1 of 2; misses “Feature requests are features” on c2.")

    // Unchanged reviews keep the version; a later skip of c1 drops its check in v2.
    let built = try await sink.events(from: 1).filter { $0.type == LearnedCheckEventType.built }
    #expect(try await checks.build(steward: learnSteward).version == 1)
    #expect(
        try await sink.events(from: 1).filter { $0.type == LearnedCheckEventType.built }.count
            == built.count)
    try await queue.record(
        .skipped, caseID: CaseID(rawValue: "c1")!, casebook: book, steward: learnSteward,
        person: "person:alex")
    let second = try await checks.build(steward: learnSteward)
    #expect(second.version == 2)
    #expect(second.removed == ["c1/decisions.choice=bug"] && second.added.isEmpty)
}

@Test func learnedCheckSentences() {
    let check = LearnedCheck(
        id: "c/x", caseID: CaseID(rawValue: "c")!, text: "Chooses bug (agreed)",
        check: RubricCheck(kind: .equals, path: "decisions.choice", value: "bug"),
        origin: .agreed, by: "local")
    let pass = LearnedCheckResult(check: check, passed: true, found: "choice: bug")
    let open = LearnedCheckResult(check: check, passed: nil, found: "not rehearsed")
    #expect(
        LearnedChecks.sentence(version: 3, results: [], scored: 0)
            == "Checks v3: none yet; correct or agree with cases in the review queue.")
    #expect(
        LearnedChecks.sentence(version: 1, results: [open], scored: 0)
            == "Checks v1: 1 check from people's reviews, not rehearsed yet.")
    #expect(
        LearnedChecks.sentence(version: 2, results: [pass, pass], scored: 2)
            == "Checks v2: passes all 2 checks people taught it.")
    #expect(
        LearnedChecks.sentence(version: 2, results: [pass, open], scored: 1)
            == "Checks v2: passes 1 of 2 (1 not rehearsed).")
}
