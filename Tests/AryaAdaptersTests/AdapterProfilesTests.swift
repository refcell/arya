import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

@Test func profilesFixtureDecodes() throws {
    let book = try AdapterProfiles.load(from: Fixtures.url("adapters.json"))
    let exec = try book.profile("exec-default")
    #expect(exec.kind == .exec)
    #expect(exec.promptVia == .stdin && exec.parse == .text && exec.mcpConfig == .none)
    #expect(exec.arguments(for: "high") == ["-p"])
    let fake = try book.profile("fake")
    #expect(fake.kind == .adapter)
    #expect(fake.supportedEfforts == ["medium"])
}

@Test func protocolExampleProfileDecodes() throws {
    // The adapters.json example in docs/PROTOCOL.md.
    let text = #"""
        {"v":1,"profiles":{"exec-default":{"command":"claude","promptVia":"stdin","parse":"text",
          "args":{"low":["-p"],"medium":["-p"],"high":["-p"]},"mcpConfig":"none"}}}
        """#
    let book = try AdapterProfiles.decode(Data(text.utf8))
    #expect(try book.profile("exec-default").kind == .exec)
}

@Test func triageExampleProfilesDecode() throws {
    let url = repositoryRoot.appendingPathComponent("etc/examples/triage/adapters.json")
    let profile = try AdapterProfiles.load(from: url).profile("fake-triage")
    #expect(profile.kind == .adapter)
    #expect(profile.arguments(for: "low").first == "--script")
}

@Test func effortFallsBackToMedium() {
    let profile = AdapterProfile(command: "agent", args: ["medium": ["-m"], "high": ["-h"]])
    #expect(profile.arguments(for: "high") == ["-h"])
    #expect(profile.arguments(for: "low") == ["-m"])
    #expect(AdapterProfile(command: "agent").arguments(for: "low") == [])
    #expect(AdapterProfile(command: "agent").supportedEfforts == ["low", "medium", "high"])
}

@Test func commandsForEachKind() throws {
    let book = try AdapterProfiles.load(from: Fixtures.url("adapters.json"))
    let base = ["PATH": "/usr/bin:/bin", "FAKE_MODE": "0"]
    let fake = try book.profile("fake").command(
        name: "fake", profilesFile: "/tmp/adapters.json", effort: "low", environment: base)
    #expect(fake.executable == "arya-fake-adapter")
    #expect(fake.arguments == ["--script", "s.json"])
    #expect(fake.environment == ["PATH": "/usr/bin:/bin", "FAKE_MODE": "1"])
    let exec = try book.profile("exec-default").command(
        name: "exec-default", profilesFile: "/tmp/adapters.json", effort: "high",
        environment: base, execAdapter: "/opt/arya/arya-exec-adapter")
    #expect(exec.executable == "/opt/arya/arya-exec-adapter")
    #expect(exec.arguments == ["--profile", "exec-default", "--profiles", "/tmp/adapters.json"])
}

@Test(arguments: [
    (#"{"v":2,"profiles":{}}"#, "version"),
    (#"{"profiles":{"a":{"command":" "}}}"#, "empty command"),
    (#"{"profiles":{"a":{"command":"x","args":{"max":[]}}}}"#, "unknown effort max"),
    (#"{"profiles":{"a":{"command":"x","mcpConfig":"file"}}}"#, "{mcpConfig}"),
    (#"{"profiles":{"a":{"command":"x","parse":"xml"}}}"#, "xml"),
])
func invalidProfilesAreRejected(_ text: String, _ needle: String) {
    do {
        _ = try AdapterProfiles.decode(Data(text.utf8))
        Issue.record("expected an error")
    } catch {
        #expect(error.description.contains(needle), "\(error)")
    }
}

@Test func missingFileIsEmptyAndUnknownProfileFails() throws {
    let book = try AdapterProfiles.load(from: URL(fileURLWithPath: "/nonexistent/adapters.json"))
    #expect(book.profiles.isEmpty)
    #expect(throws: AdapterProfileError.unknownProfile("x")) { try book.profile("x") }
}

@Test func exampleProfilesAreValidAndHonest() throws {
    let examples = AdapterProfiles.examples
    try examples.validate()
    // They round-trip through adapters.json.
    let again = try AdapterProfiles.decode(try JSONEncoder().encode(examples))
    #expect(again == examples)
    for name in ["claude-code", "codex-cli"] {
        let profile = try examples.profile(name)
        #expect(profile.kind == .exec)
        #expect(profile.supportedEfforts == ["low", "medium", "high"])
        #expect(profile.sandbox == .workdir)
    }
    let claude = try examples.profile("claude-code")
    #expect(claude.arguments(for: "high").contains("opus"))
    #expect(claude.arguments(for: "low").contains("{mcpConfig}"))
    let disallowed = try #require(claude.arguments(for: "medium").last)
    for tool in ["Bash", "Edit", "Write", "WebFetch"] { #expect(disallowed.contains(tool)) }
    let codex = try examples.profile("codex-cli")
    #expect(codex.mcpConfig == .none)
    #expect(codex.arguments(for: "low").contains("model_reasoning_effort=low"))
    #expect(codex.arguments(for: "medium").contains("read-only"))
}
