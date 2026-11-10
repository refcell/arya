import Testing

@testable import AryaDesign

@Test func moduleLinks() {
    #expect(AryaDesign.name == "AryaDesign")
}

@Test func trimmingNeverCutsAWord() {
    #expect(AryaTrim.words("5 tools, every one read-only", limit: 16) == "5 tools, every…")
    #expect(AryaTrim.words("Support inbox triage", limit: 40) == "Support inbox triage")
    #expect(AryaTrim.words("Supercalifragilistic", limit: 5) == "Super…")
}
