# Lane: workspace

Owns `Sources/Arya` and `Tests/AryaTests` (taken over from the runtime lane).

Goal: **every user flow is reachable through one facade.** `Workspace` opens an arya home and
wires `AryaLedger`, `AryaAdapters`, `AryaMemory`, `AryaRuntime`, and `AryaEval` together. It is
the only API the CLI (cli-e2e lane) and the macOS app (app-views lane) use. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md), decisions in [DECISIONS.md](../DECISIONS.md).

## Backlog

Outcome first (user priority, consumed by the app-outcome lane):
- [x] `outcome(steward:windows:windowSeconds:) -> OutcomeSummary` (KPI, current, target,
  direction, success definition, trend, status vs target).
- [ ] `plan(steward:) -> Plan`: real shape, no items until runtime records plan events.
- [x] `recap(steward:since:) -> Recap` (goal, outcome, activity since a seq the app keeps,
  unresolved, pending approvals) and `activity(steward:limit:) -> [ActivityItem]`.
- [x] `createSteward(_ draft: StewardDraft)` from structured fields; `bindings(steward:)`,
  `people(steward:)`.

M4:
- [x] Scheduler control for `arya serve`: `startServing(every:)` (scheduler lock),
  `stopServing()`, `isServing`, `tick()`, `deliverMessage(_:from:to:)`, `settle()`; triggered
  runs record proposed routines through the scheduler's `finished` hook.
- [ ] People bindings: a local inbox (person-binding actions and questions) the app shows.

M1 (the facade still throws `unavailable` for these):
- [x] A ledger-backed `EventSink` for the home, then stewards, runs, approvals, ledger read,
  and verify through the runtime; restart recovery on `open`.
- [x] `replay(run:) -> ReplaySummary`: a thin call into eval's `RunReplayer` (eval owns the
  replay engine, project lead decision).
- [x] Memory and routine reads from `MemoryProjection`/`RoutineLibrary`:
  `memory(steward:includeRetracted:)`, `routines(steward:)`,
  `routine(steward:name:version:) -> RoutineDetail` (body, gate status, provenance),
  `routineContent`, `routineHistory(steward:name:)`; `caseExpected(casebook:case:)`.
- [x] Adapter launch through the public `AryaAdapters.AdapterProfiles` (exec profiles, `env`).
- [x] Eval's `CaseRunRequest.routine`: rehearsals run the candidate routine version
  (`RunRequest.routine`, a small runtime integration edit).
- [x] Gate wiring: charter proposals (`proposeCharter`, `proposals`, `proposal`,
  `checkProposal`, `acceptProposal`, `rejectProposal`, `overrideProposal`) through
  `ProposalDesk` + `RehearsalGate`; routine versions (`gateRoutine`, `overrideRoutine`)
  through `RoutineGatekeeper` + `RoutineRehearsalGate`.
- [x] Routine wiring (decisions 0025, 0031, 0032): facade runs record `run/result.routines`
  as `routine.proposed` (`RoutineProposals.intake`, bodies in blobs, not live until gated);
  `RoutineActionExecutor` runs `routine` actions with the live version (`RoutineInvocation`
  + `ShellRoutineRunner`, run scratch dir) after the per-name policy or an approval.

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
- [x] Observation API: `changes(after:)` yields the newest `seq` (newest-only buffer, other
  writers included) and `lastSeq()`; no SwiftUI import.

M3:
- [x] Restart recovery wiring on `open` (interrupted runs fail, pending approvals stay).
- [x] Facade-level end-to-end test with the fake adapter that mirrors the M3 scenario
  (`ScenarioTests`, on `etc/examples/triage`).

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
- (from runtime) Binding proxy: pass `BindingProxyLaunch(command: <arya executable>, args: ["binding-proxy", "--home", <home>])` as `RunEngine(proxy:)`; `replay` can serve a run's original answers with `ToolRecordings.from(events, run:)` as `ToolSource.recorded`.
- (from ledger) `LedgerVerification.report` (`headline`, `details`, `lines`, `text`) is a stable, locale-free verify rendering; `LedgerCheck` could carry its `lines` so the CLI and app show where, meaning, and next step.
- (from ledger) `sink.book(RunBook.self)` (AryaRuntime) serves books from `cache/`; `Workspace.runBook()` could use it instead of folding every event.
- (from eval) For the app: `RehearsalReports(sink:casebooks:).report(_:)`; judges: `AdapterJudge`.
- (from cli-e2e) Please add `serve(every:)` (holds scheduler.lock, ticks) and `serveBindingProxy(steward:run:binding:recorded:)` (stdio); CLI calls are wired.

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
- 2026-11-09: recap takes the last seen `seq` from the caller; the facade keeps no per-person
  state
- 2026-11-09: routine intake runs in the facade after each facade-started live run (runtime
  has no blob store); scheduler-started runs get it when the facade drives `arya serve` (M4)
- 2026-11-09: routine gates and overrides get a fresh proposal id (routine proposals have no
  `proposal.created`); an override records `routine.promoted` by the person, then
  `proposal.overridden` with the reason; a charter proposal title is the reason's first line
- 2026-11-09: `just e2e` after 40f9468: steps 1-2 ok, 3 PENDING (`importCasebook`: the
  facade call is live, the CLI `WorkspaceBackend` still stubs it); replay engine handed to
  eval; memory and routine reads, `caseExpected`, and public adapter profiles landed.
- 2026-11-09: `just e2e` after 53394a3: steps 1-13 and 15 ok (init, create, import, rehearse
  7/8, correct case-0006, rehearse 8/8, ready, live run, approval wait, approve, executed,
  metric recorded, series updated, verify); 14 replay PENDING on eval's `RunReplayer`.
  Rehearsals now honor `CaseRunRequest.routine`.
- 2026-11-09: charter proposals and routine gates through the facade (28 AryaTests green);
  replay waits on eval's `RunReplayer`.
- 2026-11-09: `replay(run:)` on eval's `RunReplayer`. `just e2e`: ok (15 steps): init, create,
  import, rehearse 7/8, correct case-0006, rehearse 8/8, ready, live run, approval wait,
  approve, executed, metric recorded, series updated, replay zero divergence, verify.
- 2026-11-09: routine wiring (intake, execution, approvals) and `changes(after:)`; 34 AryaTests.
- 2026-11-09: outcome-first calls (outcome, plan shape, recap, activity, structured create,
  bindings, people), serve control, M3 scenario test; 39 AryaTests.
