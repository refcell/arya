import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

private func shell(_ script: String) -> AdapterCommand {
    AdapterCommand(executable: "/bin/sh", arguments: ["-c", script])
}

@Test func probeReportsTheFakeAdapterAndItsCapabilities() async throws {
    let report = await ConnectionProbe.adapter(
        AdapterUnderTest.fake(script: "conformance-script.json"))
    #expect(report.ok, "\(report.problem ?? "")")
    #expect(report.adapter?.name == "fake")
    #expect(report.capabilities != nil)
    #expect(report.latencyMilliseconds != nil)
}

@Test func probeReportsTheExecAdapter() async throws {
    let report = await ConnectionProbe.adapter(AdapterUnderTest.execConformanceCommand)
    #expect(report.ok, "\(report.problem ?? "")")
    #expect(report.adapter?.name == "exec")
}

@Test func probeExplainsAMissingCommand() async {
    let report = await ConnectionProbe.adapter(
        AdapterCommand(executable: "/nonexistent/arya-adapter"))
    #expect(!report.ok)
    #expect(report.problem?.hasPrefix("Could not start arya-adapter") == true)
}

@Test func probeQuotesWhatACrashingCommandSaid() async {
    let report = await ConnectionProbe.adapter(shell("echo 'missing API key' >&2; exit 3"))
    #expect(!report.ok)
    let problem = report.problem ?? ""
    #expect(problem.contains("exited before answering"), "\(problem)")
    #expect(problem.hasSuffix("It said: missing API key"), "\(problem)")
}

@Test func probeGivesUpOnASilentCommand() async {
    let report = await ConnectionProbe.adapter(shell("exec sleep 30"), timeout: .seconds(1))
    #expect(!report.ok)
    #expect(report.problem == "sh did not answer initialize in time.")
}

@Test func bindingProbeListsTheFakeBindingTools() async {
    let history = repositoryRoot.appendingPathComponent("etc/examples/triage/inbox-history.json")
    let report = await ConnectionProbe.binding(
        AdapterCommand(
            executable: AdapterUnderTest.fakeAdapterPath,
            arguments: ["--binding", history.path]))
    #expect(report.ok, "\(report.problem ?? "")")
    #expect(report.server?.name == "arya-fake-binding")
    #expect(report.tools == ["history", "outcome", "directory", "process", "get", "search"])
    #expect(report.servesHistory)
}

@Test func bindingProbeExplainsAServerThatIsNotMCP() async {
    // An adapter is not a binding: it rejects MCP's initialize params.
    let report = await ConnectionProbe.binding(
        AdapterUnderTest.fake(script: "conformance-script.json"))
    #expect(!report.ok)
    #expect(report.problem?.contains("refused the connection") == true, "\(report.problem ?? "")")
}

@Test func pingAnswersFromBothReferenceAdapters() async throws {
    for command in [
        AdapterUnderTest.fake(script: "conformance-script.json"),
        AdapterUnderTest.execConformanceCommand,
    ] {
        let connection = try AdapterUnderTest.launch(command)
        #expect(try await connection.request(RPCMethod.ping) == [:])
        try await connection.shutdown()
    }
}
