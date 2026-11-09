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
- [ ] `replay(run:) -> ReplaySummary`: a thin call into eval's `RunReplayer` (eval owns the
  replay engine, project lead decision); the facade shape is published and throws
  `unavailable` until it lands.
- [x] Memory and routine reads from `MemoryProjection`/`RoutineLibrary`:
  `memory(steward:includeRetracted:)`, `routines(steward:)`,
  `routine(steward:name:version:) -> RoutineDetail` (body, gate status, provenance),
  `routineContent`, `routineHistory(steward:name:)`; `caseExpected(casebook:case:)`.
- [x] Adapter launch through the public `AryaAdapters.AdapterProfiles` (exec profiles, `env`).
- [x] Eval's `CaseRunRequest.routine`: rehearsals run the candidate routine version
  (`RunRequest.routine`, a small runtime integration edit).
- [ ] Gate wiring: `RoutineRehearsalGate` into `RoutineGatekeeper`, `RehearsalGate` into
  `ProposalDesk`/`GateChecking`.

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
- (from app-views) the charter editor records proposals: proposed `Workspace.proposeCharter(steward:charter: Data, baseVersion:title:reason:) -> ProposalSummary` (refuse when `baseVersion` is no longer live); until then the app shows "unavailable" on save.

## Log

- 2026-11-09: lane created; `Sources/Arya` and `Tests/AryaTests` move here from runtime
- 2026-11-09: `RuntimeCaseRunner` (runtime-backed `CaseRunner`) for eval rehearsals
- 2026-11-09: core facade on the real ledger: stewards, effort, runs, approvals, ledger,
  events, verify, restart recovery
- 2026-11-09: M2 calls: casebooks, rehearse, correct, ready, metrics, and `run(_:)` detail
- 2026-11-09: replay is a thin call into eval's `RunReplayer` (eval owns the engine)
- 2026-11-09: routine reads take a steward (`RoutineLibrary` keys by steward and name);
  `caseExpected` returns canonical JSON `Data`, like `charter(_:)`, so the app needs no
  `AryaCore` import
- 2026-11-09: `just e2e` after 40f9468: steps 1-2 ok, 3 PENDING (`importCasebook`: the
  facade call is live, the CLI `WorkspaceBackend` still stubs it); replay engine handed to
  eval; memory and routine reads, `caseExpected`, and public adapter profiles landed.
- 2026-11-09: `just e2e` after 53394a3: steps 1-13 and 15 ok (init, create, import, rehearse
  7/8, correct case-0006, rehearse 8/8, ready, live run, approval wait, approve, executed,
  metric recorded, series updated, verify); 14 replay PENDING on eval's `RunReplayer`.
  Rehearsals now honor `CaseRunRequest.routine`.
