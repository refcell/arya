# Lane: workspace

Owns `Sources/Arya` and `Tests/AryaTests` (taken over from the runtime lane).

Goal: **every user flow is reachable through one facade.** `Workspace` opens an arya home and
wires `AryaLedger`, `AryaAdapters`, `AryaMemory`, `AryaRuntime`, and `AryaEval` together. It is
the only API the CLI (cli-e2e lane) and the macOS app (app-views lane) use. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md), decisions in [DECISIONS.md](../DECISIONS.md).

## Backlog

M1 (the facade still throws `unavailable` for these):
- [x] A ledger-backed `EventSink` for the home, then stewards, runs, approvals, ledger read,
  and verify through the runtime; restart recovery on `open`.
- [ ] `replay(run:) -> ReplayReport` with a divergence report (drive the run again with
  `ReplayAdapter` and a recorded ambient into a scratch sink; compare derived events).
- [ ] `routine(name:version:) -> RoutineDetail` and `routineHistory(name:)` from
  `RoutineLibrary` (app-views: routine history and diff).

M2 (top priority first):
- [x] Runtime-backed `AryaEval.CaseRunner` in `Sources/Arya` (the runtime cannot import eval):
  one run with trigger kind `case` for `request.caseItem`, tool reads answered from its
  `context.toolResults`, no action executed; returns the run id, a result shaped like the
  case's `expected`, and `leak` (`RuntimeCaseRunner`). Plugs into `CasebookRehearser`.
- [x] cli-e2e facade additions (all but `replay`, next): `charter(_ id:) -> Data` (live charter), `run(_ id:) ->
  RunDetail` (decisions and per-action dispositions), and the calls behind `casebook import`,
  `rehearse`, `correct`, `ready`, `metrics`, and `replay`.
- [x] Effort (decision 0026): `effort(for:)` and `setEffort(_:for:by:)`, recording
  `steward.effort.set`; tell app-shell in its lane file once it lands.
- [ ] Routine wiring (decision 0025, from memory): feed `run/result.routines` to
  `RoutineProposals.intake`, gate with `RoutineGatekeeper` through eval's
  `RoutineGateChecking` conformance, and execute `routine` actions with
  `RoutineInvocation.prepare` + `ShellRoutineRunner` (output is `RoutineOutcome`).
- [ ] Observation API the app can subscribe to (new ledger events lead to a refresh), with no
  SwiftUI import in the facade.

M3:
- [x] Restart recovery wiring on `open` (interrupted runs fail, pending approvals stay).
- [ ] Facade-level end-to-end test with the fake adapter that mirrors the M3 scenario.

## Decisions

- Inherits the runtime lane's facade decisions: ids are `String`, read models are facade-owned
  values, and a call whose backing module has not landed throws `WorkspaceError.unavailable`.
- Canonical `approval.requested` payload is the runtime's `{approval, kind, action}` with a
  full `ProposedAction` (project lead decision).

- `RuntimeCaseRunner` passes the charter to the run loop only when it differs from the live
  charter at the requested version, so live rehearsals record the live `charterVersion` and
  candidates record 0. The scored result is the whole `run/result` as JSON; a failed run scores
  against `{}` and keeps its run id.
- `Arya` depends on every library module (ledger, adapters, memory, runtime, eval); it is the
  one place they meet.

- The facade runs on the runtime's `LedgerEventSink` over the home's ledger; every
  call reads state from the ledger, so the CLI and the app can share a home. Run leases live in
  `cache/runs`, run scratch directories in `cache/work/<run>`, and `open` runs
  `RunRecovery` with the same file leases the engine holds.
- Adapters come from `home/adapters.json` (`{v, profiles: {name: {command, args: {effort:
  [...]}}}}`), read at each run. `open(home:environment:)` takes the complete adapter process
  environment from the entry point. A missing profile fails the run (`adapter_exited`).
- Until binding executors land (M4), approved and `auto` actions go to `DryRunExecutor`, which
  records `action.executed` with output `{"dryRun": true}`.
- `verifyLedger().firstBadSeq` is the count of good events plus one.
- M2 facade: casebooks come from `casebook.imported` events plus their blobs (`HomeCasebooks`);
  `rehearse` defaults to the steward's newest imported casebook and `gate.samples`;
  `markReady` cites the newest finished live rehearsal of the live version as evidence;
  `expected(steward:case:choice:)` builds the corrected expected result for a choice so the
  CLI's `--choice` needs no JSON. Metrics are `OutcomeMetrics.series` in UTC-day windows.

## Questions

- Moved here from runtime: the eval `CaseRunner` (done), the cli-e2e facade additions,
  app-shell's effort selector, and memory's routine wiring (backlog items above).
- (from memory) Facade memory/routine API can map `MemoryProjection(ledger:)`, `RoutineLibrary(ledger:)`, `allNotes`, `overview`, `history`, `diff(…store:)`, `RunPreparation.context`, `MemoryIntake.notes`, `RoutineProposals.intake` (see memory.md Decisions).
- (from eval) `CaseRunRequest.routine` names a candidate routine: run the case with `RoutineLibrary.candidateRoutines(for:)` instead of the live routines; wire `AryaEval.RoutineRehearsalGate` into `RoutineGatekeeper` and `RehearsalGate` into `ProposalDesk`/`GateChecking`.
- (from app-views) the app also needs a case's expected result for rehearsal review: proposed `Workspace.caseExpected(casebook:case:) -> JSONValue?` (nil when missing), alongside the planned `routine(name:version:)`.
- (from adapters) `AryaAdapters.AdapterProfiles` is public now (validation, `env`, exec profiles); proposed default: replace the internal `AdapterProfiles` in `Sources/Arya/AdapterProfiles.swift` with `try AdapterProfiles.load(from:).profile(charter.adapter).command(name:profilesFile:effort:environment:)`.

## Log

- 2026-11-09: lane created; `Sources/Arya` and `Tests/AryaTests` move here from runtime
- 2026-11-09: `RuntimeCaseRunner` (runtime-backed `CaseRunner`) for eval rehearsals
- 2026-11-09: core facade on the real ledger: stewards, effort, runs, approvals, ledger,
  events, verify, restart recovery
- 2026-11-09: M2 calls: casebooks, rehearse, correct, ready, metrics, and `run(_:)` detail
