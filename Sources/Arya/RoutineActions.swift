import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation

// Routine wiring (decisions 0025, 0031, 0032): routines a live run proposes become
// `routine.proposed` versions that go live only through a gate or a person, and `routine`
// actions run the live version once policy (or an approval) allows it.

/// Carries out `routine` actions with the steward's live routine version and hands every
/// other action kind to `fallback`. The body comes from the home's blobs (hash-checked); the
/// script runs in the run's scratch directory with a clean environment and a timeout.
struct RoutineActionExecutor: ActionExecutor {
    let home: URL
    let fallback: any ActionExecutor
    let runner: any RoutineRunning

    func execute(_ request: ExecutionRequest) async -> ExecutionOutcome {
        guard request.action.kind == ActionPolicy.routineKind else {
            return await fallback.execute(request)
        }
        let invocation: RoutineInvocation
        do {
            invocation = try prepare(request)
        } catch {
            return .failed(error: "routine: \(error)", output: nil)
        }
        let runner = runner
        let result = await Task.detached { () -> Result<RoutineOutcome, RoutineExecutionError> in
            do throws(RoutineExecutionError) {
                return .success(try runner.run(invocation))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .failure(let error):
            return .failed(error: "routine \(invocation.name): \(error)", output: nil)
        case .success(let outcome):
            let output = (try? CanonicalJSON.jsonValue(outcome)) ?? .null
            guard outcome.status == .exited, outcome.exitCode == 0 else {
                return .failed(error: Self.describe(outcome), output: output)
            }
            return .succeeded(output: output)
        }
    }

    private func prepare(_ request: ExecutionRequest) throws -> RoutineInvocation {
        let library = try RoutineLibrary(ledger: try LedgerReader(home: home).events())
        let workdir = HomeLayout.work(home, run: request.run)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        return try RoutineInvocation.prepare(
            params: request.action.params ?? [:], steward: request.steward, library: library,
            store: BlobStore(home: home), workdir: workdir)
    }

    static func describe(_ outcome: RoutineOutcome) -> String {
        switch outcome.status {
        case .exited: "routine \(outcome.name) exited with \(outcome.exitCode ?? -1)"
        case .signaled: "routine \(outcome.name) killed by signal \(outcome.signal ?? -1)"
        case .timedOut: "routine \(outcome.name) timed out"
        }
    }
}

/// Records the routines a finished live run proposed (`routine.proposed`, the steward as
/// actor), storing each body in the home's blobs. Invalid routines and versions already on the
/// ledger are skipped. None go live here: `gateRoutine` or a person promotes them. Used after
/// facade-started runs and, through the scheduler's `finished` hook, after triggered ones.
struct RoutineRecorder: Sendable {
    let home: URL
    let sink: LedgerEventSink

    func record(_ outcome: RunOutcome) async throws {
        guard let routines = outcome.result?.routines, !routines.isEmpty else { return }
        let events = try await sink.events(from: 1)
        let started = events.last {
            $0.type == RunEventType.started && $0.draft.run == outcome.run
        }
        guard let steward = started?.draft.steward else { return }
        let intake = try RoutineProposals.intake(
            routines.map {
                ProposedRoutine(
                    name: $0.name, language: $0.language, content: $0.content, reason: $0.reason)
            },
            steward: steward, run: outcome.run,
            library: try RoutineLibrary(ledger: try LedgerReader(home: home).events()),
            store: BlobStore(home: home))
        for draft in intake.drafts {
            _ = try await sink.append(RuntimeEventDraft(draft))
        }
    }
}
