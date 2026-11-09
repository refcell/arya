import AryaCore
import Foundation
import Testing

@testable import AryaMemory

/// A fresh temp directory removed after `body`.
func withTempDir<R>(_ body: (URL) throws -> R) throws -> R {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-memory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func invocation(
    _ content: String, in dir: URL, args: [String] = [], input: String? = nil,
    timeoutSeconds: Int = 10, maxOutputBytes: Int = 1024
) -> RoutineInvocation {
    RoutineInvocation(
        name: "test-routine", version: RoutineNaming.version(of: Data(content.utf8)),
        content: content, arguments: args, input: input, workdir: dir,
        timeoutSeconds: timeoutSeconds, maxOutputBytes: maxOutputBytes)
}

@Suite struct RoutineExecutionTests {
    let runner = ShellRoutineRunner()

    @Test func capturesOutputArgumentsAndInput() throws {
        try withTempDir { dir in
            let script = "echo \"$0:$1:$2\"; tr a-z A-Z; echo oops >&2"
            let outcome = try runner.run(
                invocation(script, in: dir, args: ["one", "two words"], input: "abc\n"))
            #expect(outcome.succeeded)
            #expect(outcome.stdout == "test-routine:one:two words\nABC\n")
            #expect(outcome.stderr == "oops\n")
            #expect(!outcome.stdoutTruncated)
        }
    }

    @Test func runsInTheWorkdirWithACleanEnvironment() throws {
        try withTempDir { dir in
            let script = "pwd -P; echo \"$HOME|$ARYA_ROUTINE|${USER:-unset}\"; touch made"
            let outcome = try runner.run(invocation(script, in: dir))
            let real = try #require(
                realpath(dir.path, nil).map { p in
                    defer { free(p) }
                    return String(cString: p)
                })
            #expect(outcome.stdout == "\(real)\n\(dir.path)|test-routine|unset\n")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("made").path))
        }
    }

    @Test func reportsExitCodesAndSignals() throws {
        try withTempDir { dir in
            let failed = try runner.run(invocation("echo partial; exit 3", in: dir))
            #expect(failed.status == .exited)
            #expect(failed.exitCode == 3)
            #expect(failed.stdout == "partial\n")
            #expect(!failed.succeeded)
            let killed = try runner.run(invocation("kill -TERM $$", in: dir))
            #expect(killed.status == .signaled)
            #expect(killed.signal == SIGTERM)
        }
    }

    @Test func timesOutAndKillsTheProcessGroup() throws {
        try withTempDir { dir in
            let script = "(sleep 30; touch late) & echo started; sleep 30"
            let started = Date()
            let outcome = try runner.run(invocation(script, in: dir, timeoutSeconds: 1))
            #expect(outcome.status == .timedOut)
            #expect(outcome.stdout == "started\n")
            #expect(Date().timeIntervalSince(started) < 10)
        }
    }

    @Test func backgroundChildrenDoNotOutliveTheRoutine() throws {
        try withTempDir { dir in
            let outcome = try runner.run(invocation("sleep 30 & echo done", in: dir))
            #expect(outcome.succeeded)
            #expect(outcome.stdout == "done\n")
        }
    }

    @Test func truncatesLargeOutput() throws {
        try withTempDir { dir in
            let script = "i=0; while [ $i -lt 2000 ]; do echo 0123456789; i=$((i+1)); done"
            let outcome = try runner.run(invocation(script, in: dir, maxOutputBytes: 100))
            #expect(outcome.succeeded)
            #expect(outcome.stdout.utf8.count == 100)
            #expect(outcome.stdoutTruncated)
        }
    }

    @Test func ignoresUnreadInput() throws {
        try withTempDir { dir in
            let input = String(repeating: "x", count: 1_000_000)
            let outcome = try runner.run(invocation("echo ok", in: dir, input: input))
            #expect(outcome.succeeded)
            #expect(outcome.stdout == "ok\n")
        }
    }

    @Test func rejectsAMissingWorkdir() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-arya")
        #expect(throws: RoutineExecutionError.workdirMissing("nope-arya")) {
            try runner.run(invocation("true", in: missing))
        }
    }

    @Test func outcomeMatchesGolden() throws {
        let outcome = RoutineOutcome(
            name: "label-issue", version: String(repeating: "a", count: 64), status: .exited,
            exitCode: 0, stdout: "auth\n")
        #expect(try encodeJSON(outcome) == (try fixture("routine.outcome.json")))
    }
}

@Suite struct RoutineInvocationTests {
    func library(_ store: InMemoryRoutineBlobStore) throws -> (RoutineLibrary, RoutineSource) {
        let source = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        let note = try RoutineSource(name: "tone", language: .prompt, content: "Be brief.")
        let p = RoutineEventType.self
        let library = try RoutineLibrary(events: [
            routineEvent(seq: 1, type: p.proposed, try source.propose(into: store)),
            routineEvent(
                seq: 2, type: p.promoted,
                RoutinePromotedPayload(name: source.name, version: source.version)),
            routineEvent(seq: 3, type: p.proposed, try note.propose(into: store)),
            routineEvent(
                seq: 4, type: p.promoted,
                RoutinePromotedPayload(name: note.name, version: note.version)),
        ])
        return (library, source)
    }

    @Test func preparesTheLiveVersionFromParams() throws {
        let store = InMemoryRoutineBlobStore()
        let (library, source) = try library(store)
        let dir = URL(fileURLWithPath: "/tmp")
        let params: JSONValue = [
            "name": "label-issue", "version": .string(source.version), "args": ["ISSUE-1"],
            "input": "body",
        ]
        let prepared = try RoutineInvocation.prepare(
            params: params, steward: "st_triage", library: library, store: store, workdir: dir)
        #expect(prepared.content == labelV1)
        #expect(prepared.version == source.version)
        #expect(prepared.arguments == ["ISSUE-1"])
        #expect(prepared.input == "body")
    }

    @Test func refusesWhatCannotRun() throws {
        let store = InMemoryRoutineBlobStore()
        let (library, source) = try library(store)
        let dir = URL(fileURLWithPath: "/tmp")
        func prepare(_ params: JSONValue) throws(RoutineActionError) {
            _ = try RoutineInvocation.prepare(
                params: params, steward: "st_triage", library: library, store: store,
                workdir: dir)
        }
        #expect(throws: RoutineActionError.missingName) { try prepare([:]) }
        #expect(throws: RoutineActionError.notLive("other")) { try prepare(["name": "other"]) }
        #expect(throws: RoutineActionError.notExecutable(name: "tone", language: .prompt)) {
            try prepare(["name": "tone"])
        }
        #expect(
            throws: RoutineActionError.versionMismatch(
                name: "label-issue", live: source.version, requested: "abc")
        ) {
            try prepare(["name": "label-issue", "version": "abc"])
        }
        #expect(throws: RoutineActionError.invalidParams("args must be an array of strings")) {
            try prepare(["name": "label-issue", "args": [1]])
        }
        #expect(throws: RoutineActionError.notLive("label-issue")) {
            _ = try RoutineInvocation.prepare(
                params: ["name": "label-issue"], steward: "st_inbox", library: library,
                store: store, workdir: dir)
        }
    }

    @Test func preparedRoutineRunsEndToEnd() throws {
        let store = InMemoryRoutineBlobStore()
        let (library, _) = try library(store)
        try withTempDir { dir in
            try "Login page times out".write(
                to: dir.appendingPathComponent("issue.txt"), atomically: true, encoding: .utf8)
            let prepared = try RoutineInvocation.prepare(
                params: ["name": "label-issue", "args": ["issue.txt"]], steward: "st_triage",
                library: library, store: store, workdir: dir)
            let outcome = try ShellRoutineRunner().run(prepared)
            #expect(outcome.succeeded)
            #expect(outcome.stdout == "auth\n")
        }
    }
}
