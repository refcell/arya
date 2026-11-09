import Foundation
import Testing

@testable import AryaApp

@Test func routineStatusIsOnePlainWord() {
    func routine(live: Bool, pending: Int) -> FeatureKnowledge.Routine {
        FeatureKnowledge.Routine(
            name: "flag-duplicates", summary: "", versions: [], isLive: live, pending: pending)
    }
    #expect(routine(live: true, pending: 0).status == "live")
    #expect(routine(live: false, pending: 0).status == "not live")
    #expect(routine(live: true, pending: 1).status == "waiting")
}

@Test func noteProvenanceIsOneLineWithoutIds() {
    let note = FeatureKnowledge.Note(
        id: "mem_01ABC", text: "Card questions are billing.",
        provenance: "From your correction to case case-0006.", time: "4 weeks ago",
        absoluteTime: "2026-10-12 09:00", run: "run_01XYZ")
    let line = KnowledgeText.provenance(note)
    #expect(line == "From your correction to case case-0006 · 4 weeks ago")
    #expect(!line.contains("mem_") && !line.contains("run_"))
    #expect(KnowledgeText.shortVersion("sha256:1a2b3c4d5e6f") == "1a2b3c4d")
}

@Test func autonomyHoldsReadAsSentences() {
    #expect(
        PolicyText.autonomy("autonomy:suggest:low")
            == "This steward only suggests changes, so a person approves each action.")
    #expect(PolicyText.autonomy("autonomy:act_low:medium").contains("this one is medium risk"))
    #expect(!PolicyText.autonomy("autonomy:act_low:high").contains("autonomy:"))
}
