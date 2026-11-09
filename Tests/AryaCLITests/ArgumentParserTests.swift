import Testing

@testable import AryaCLI

private let parser = ArgumentParser(commands: CommandTable.all)

private func invocation(_ arguments: [String]) throws -> Invocation {
    guard case .run(let invocation) = try parser.parse(arguments) else {
        Issue.record("expected a command for \(arguments)")
        throw CLIError.failed("not a command")
    }
    return invocation
}

private func usageError(_ arguments: [String]) -> CLIError? {
    do {
        _ = try parser.parse(arguments)
        return nil
    } catch {
        return error
    }
}

@Test func everyCommandHasAUniquePathAndASummary() {
    let paths = CommandTable.all.map(\.path)
    #expect(Set(paths.map { $0.joined(separator: " ") }).count == paths.count)
    #expect(CommandTable.all.map(\.id) == CommandID.allCases)
    for spec in CommandTable.all { #expect(!spec.summary.isEmpty, "\(spec.id)") }
}

@Test func parsesSubcommandsAndPositionals() throws {
    let show = try invocation(["steward", "show", "st_triage"])
    #expect(show.command == .stewardShow)
    #expect(show.positionals == ["steward": "st_triage"])

    let run = try invocation(["run", "st_triage", "--input", "New message: refund"])
    #expect(run.command == .run)
    #expect(run.values == ["input": "New message: refund"])
}

@Test func parsesOptionForms() throws {
    #expect(try invocation(["ledger", "tail", "--count", "5"]).values["count"] == "5")
    #expect(try invocation(["ledger", "tail", "--count=7"]).values["count"] == "7")
    #expect(try invocation(["ledger", "tail", "-n", "9"]).values["count"] == "9")
    #expect(try invocation(["approvals", "--all"]).flags == ["all"])
    let tail = try invocation(["ledger", "tail", "--steward", "st_a", "-n", "3"])
    #expect(tail.values == ["steward": "st_a", "count": "3"])
}

@Test func globalOptionsWorkAnywhere() throws {
    let a = try invocation(["--home", "/tmp/a", "steward", "list", "--json"])
    #expect(a.global == GlobalOptions(home: "/tmp/a", isJSON: true))
    let b = try invocation(["steward", "--home=/tmp/b", "list"])
    #expect(b.global.home == "/tmp/b")
    #expect(b.command == .stewardList)
}

@Test func doubleDashEndsOptions() throws {
    let run = try invocation(["run", "--", "--odd-id"])
    #expect(run.positionals == ["steward": "--odd-id"])
}

@Test func requiredOptionIsEnforced() throws {
    #expect(
        usageError(["steward", "create"]) == .usage("missing --charter", command: .stewardCreate))
    let create = try invocation(["steward", "create", "--charter", "c.json"])
    #expect(create.values == ["charter": "c.json"])
}

@Test(arguments: [
    (["bogus"], CLIError.usage("unknown command: bogus")),
    (["steward"], .usage("steward needs a subcommand: create, list, show")),
    (["steward", "bogus"], .usage("unknown command: steward bogus")),
    (["run"], .usage("missing <steward>", command: .run)),
    (["run", "a", "b"], .usage("unexpected argument b", command: .run)),
    (["approvals", "--nope"], .usage("unknown option --nope", command: .approvals)),
    (["approvals", "--all=yes"], .usage("--all takes no value", command: .approvals)),
    (["ledger", "tail", "--count"], .usage("--count needs <n>", command: .ledgerTail)),
    (["--home"], .usage("--home needs a directory")),
    (["--frobnicate"], .usage("expected a command before --frobnicate")),
])
func rejectsBadCommandLines(arguments: [String], expected: CLIError) {
    #expect(usageError(arguments) == expected)
}

@Test func helpAndVersion() throws {
    #expect(try parser.parse([]) == .help(path: [], global: GlobalOptions()))
    #expect(try parser.parse(["--help"]) == .help(path: [], global: GlobalOptions()))
    #expect(try parser.parse(["steward", "--help"]) == .help(path: ["steward"], global: .init()))
    #expect(
        try parser.parse(["steward", "show", "-h"])
            == .help(path: ["steward", "show"], global: .init()))
    #expect(
        try parser.parse(["help", "ledger", "tail"])
            == .help(path: ["ledger", "tail"], global: .init()))
    #expect(try parser.parse(["run", "x", "--version"]) == .version)
}

@Test func integerOptionsAreValidated() throws {
    let tail = try invocation(["ledger", "tail", "-n", "many"])
    #expect(
        throws: CLIError.usage(
            "--count needs a non-negative integer, got many", command: .ledgerTail)
    ) {
        try tail.int("count", default: 20)
    }
    #expect(try invocation(["ledger", "tail"]).int("count", default: 20) == 20)
}

@Test func usageLinesListPositionalsThenOptions() {
    #expect(CommandTable.spec(.run).usage == "arya run <steward> [--input <text>]")
    #expect(CommandTable.spec(.stewardCreate).usage == "arya steward create --charter <file>")
    #expect(CommandTable.spec(.approve).usage == "arya approve <approval> [--note <text>]")
}
