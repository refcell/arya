# Lane: workspace

Owns `Sources/Arya` and `Tests/AryaTests` (taken over from the runtime lane).

Goal: **every user flow is reachable through one facade.** `Workspace` opens an arya home and
wires `AryaLedger`, `AryaAdapters`, `AryaMemory`, `AryaRuntime`, and `AryaEval` together. It is
the only API the CLI (cli-e2e lane) and the macOS app (app-views lane) use. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md), decisions in [DECISIONS.md](../DECISIONS.md).

## Backlog

Approval block and run threads (redesign):
- [x] `ApprovalSummary.content` (params as text), `params`, `source` (the run input),
  `policyRule`, `policyText` (the rule's `note`, else a sentence), `risk` and `why` (from the
  recorded result); `approval(_:)` for one item.
- [x] `RunSummary.title` (summary, else the input's first line, about 60 characters);
  `DecisionSummary` (`choice`, `why`); `startRun(steward:)` with no input.

Outcome first (user priority, consumed by the app-outcome lane):
- [x] `outcome(steward:windows:windowSeconds:) -> OutcomeSummary` (KPI, current, target,
  direction, success definition, trend, status vs target).
- [x] `plan(steward:) -> Plan` from the newest live run's recorded `run/result.plan`; switch
  to runtime plan events when they land.
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
- [x] `whatIf(run:proposal:)` via eval's `Counterfactuals(runner: RuntimeCaseRunner)`.

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

- (from app-outcome) Could proposal summaries carry `impact: outcome | metric | guardrails |
  routine | oversight` (plus removed guardrails, loosened actions, and oversight cuts: a
  report stopped, recipients dropped, a longer cadence, approvers removed)? The app
  classifies proposed vs live charter today (`ProposalImpact`) and would switch to the
  facade read.

- Moved here from runtime: the eval `CaseRunner` (done), the cli-e2e facade additions,
  app-shell's effort selector, and memory's routine wiring (backlog items above).
- (from runtime) Binding proxy: pass `BindingProxyLaunch(command: <arya executable>, args: ["binding-proxy", "--home", <home>])` as `RunEngine(proxy:)`; `replay` can serve a run's original answers with `ToolRecordings.from(events, run:)` as `ToolSource.recorded`.
- (from ledger) `LedgerVerification.report` (`headline`, `details`, `lines`, `text`) is a stable, locale-free verify rendering; `LedgerCheck` could carry its `lines` so the CLI and app show where, meaning, and next step.
- (from ledger) `sink.book(RunBook.self)` (AryaRuntime) serves books from `cache/`; `Workspace.runBook()` could use it instead of folding every event.
- (from eval) For the app: `RehearsalReports(sink:casebooks:).report(_:)`; judges: `AdapterJudge`.
- (from cli-e2e) Please add `serve(every:)` (holds scheduler.lock, ticks) and `serveBindingProxy(steward:run:binding:recorded:)` (stdio); CLI calls are wired.
- (from eval) Read models: `Backtester.run`/`Backtests.compare`, `ReadinessReports.report`, `OutcomeTrends.trend`.
- (from ledger) For outcome, recap, and activity views: `LedgerReader.events(since:)`, `events(_ filter:, from:)` (`LedgerFilter` now has `since`/`until`), and typed `events(ApprovalGranted.self, matching:)` skip non-matching lines before hashing; 50k events, filtered scan 0.09 s CPU vs 0.77 s full read. Please read through these instead of `events()` + filter. For "last N" (recap, activity) use `newest(filter, limit:)`: 50k events in 0.008 s. Status widgets: `LedgerIndex.stewards[id]` has `counts`, `lastSeqByType`, `openApprovals`.
- (from eval) Facade asks: `correct(run:expected:)` via `Corrector.correct(run:...)`; `whatIf(run:)` via `Counterfactuals(runner: RuntimeCaseRunner)`.
- (from ledger) For outcome, recap, and activity views: `LedgerReader.events(since:)`, `events(_ filter:, from:)` (`LedgerFilter` now has `since`/`until`), and typed `events(ApprovalGranted.self, matching:)` skip non-matching lines before hashing; 50k events, filtered scan 0.09 s CPU vs 0.77 s full read. Please read through these instead of `events()` + filter.
- (from runtime) Inbox (decision 0039): the facade can post with `Inbox(engine:scheduler:).post(text, from: personBinding, to:, intent: .ask|.correct|.handoff)` (or `RuntimeService.inbox`) and list threads with `InboxBook(events).threads[steward]`.
- (from eval) Before-live gate: `LiveReadinessGate.check(...)` (summary verbatim); `CasebookBuilder.harvest(steward:into:)`.
- (from runtime) Sandbox (decision 0040): small integration edit in `Wiring` (`routines: SandboxedRoutineRunner()`, `sandbox = true`); when real binding executors replace `DryRunExecutor`, use `BindingActionExecutor(connectForRun: BindingActionExecutor.sandboxed(workdir:))`.
- (from runtime) Schedule visibility: `Scheduler.status(now:recent:)` (or `RuntimeService.schedule(recent:)`) gives each steward's `ScheduleStatus {state: off|unscheduled|running|due|waiting, intervalSeconds, nextWake, recent: [TriggerOutcome]}` for the steward header.
- (from app-outcome) the Overview reads `plan.updated` `{v: 1, steps: [{id, title, status: todo|doing|done|dropped|blocked, note?}], reason?}`; please have `plan(steward:)` fold that event (and runtime record it from `run/result.plan`), so the app can switch to the facade reads; also an optional charter `success` sentence.
- (from runtime) `plan.updated` is live (decision 0035): `plan(steward:)` can read `PlanBook(events).plans[id]` and the newest event's `PlanUpdated {items: [{id, text, status, rationale?}], reason?}`; the app's `OutcomeFeed` expects `{steps: [{title, note}]}` and should adapt to this shape.
- (from runtime) Approval cards: `action.proposed` now has `risk` (low|medium|high) and `autonomy`, and `reason` `autonomy:<level>:<risk>` when autonomy made it ask (decision 0037); charters carry `autonomy` and `policy.risk`.
- (from eval) Facade asks: `correct(run:expected:)` via `Corrector.correct(run:...)`; `whatIf(run:)` via `Counterfactuals(runner: RuntimeCaseRunner)`.
- (from runtime) Inbox (decision 0039): the facade can post with `Inbox(engine:scheduler:).post(text, from: personBinding, to:, intent: .ask|.correct|.handoff)` (or `RuntimeService.inbox`) and list threads with `InboxBook(events).threads[steward]`.
- (from eval) Improve needs `LiveReadinessGate.check` per open proposal; demo has one (case-0005 regressed).
- (from runtime) Integration edit: `Workspace.risk(kind:binding:steward:)` in `Outcome.swift` (CEO request; resolution in `Policy.risk(ofAction:)`, decision 0037); the app-outcome Question it answered is removed.
- (from app-views) proposed: put the held action's change on the approval as data, e.g. `change: {field, from, to}` in `approval.requested` (or `ApprovalSummary.change`), so the app can show `label  none → billing` for label and route approvals; the app renders it as soon as the field exists.
- (from cli-e2e) A fleet read for M3.5, one call for every steward: state, metric value against
  target and on-track status, pending approvals, last run, next wake. The demo home now seeds
  three stewards (on track, behind, paused); `arya steward list` would show it too.
- (from eval) Added `liveReadiness(proposal:recent:)`; case runner scores crews on the join result.
- (from governance) Integration edits: `ApprovalSummary.approvers`/`approverNote` (filled in `detailed`), `approve(_:note:as:)` with an approver check before the grant (`approve(_:note:)` unchanged); new `Governance.swift` (`policySummary`, `checkApprover`) is governance-owned.
- (from governance) Integration edit: `Workspace.leases` (from `Wiring`); `abortRun` lives in `Governance.swift`.
- (from governance) Integration edit (G4): `Workspace.keys` and `Wiring.keys` (default the Keychain store), `open(home:environment:ambient:keys:)`, and `HomeEncryption.register` in `open(home:wiring:)`; the test helper `Opened` takes `keys:` (default in-memory). Decision 0048.
- (from connect) `Sources/Arya/Connections.swift` adds `CredentialStore` (Keychain and memory)
  and `ConnectionProbe`; please wire a `CredentialStore` into `Workspace.open` so `arya serve`
  and the app hand binding servers their secret once runtime takes a provider.
- (from app-views) proposed: a facade call for the run-thread composer, `message(steward:text:intent:by:)` that posts `inbox.message` (decision 0039, intent ask, correct, or handoff) as the local person and starts the message run when the charter allows; today only `deliverMessage(_:from:to:)` exists and it needs a person binding. The app's `FeatureWrite.message` forwards to it as soon as it lands.
- (from runtime) Integration edits: `Workspace.context(steward:)` in new `Context.swift` (decision 0047); `approve`/`deny` start a re-plan on a setback through the scheduler (decision 0046), so ledger tails after a deny now include the re-plan run (`settle()` first).
- (from connect) Integration edit: the serve loop in `startServing` calls `sendDueReports()`
  after each tick; reports live in the connect-owned `Sources/Arya/Reports.swift`
  (`reportDigest`, `sendReport`, `dueReports`, `sendDueReports`; charter `report`, event
  `report.sent`).

- (from eval) Added Sources/Arya/History.swift: importHistory, reviewQueue, reviewCase.
- (from runtime) Integration edit (decision 0051): `startServing(every:demoPace:)` turns on `Scheduler.setDemoPace(DemoPacer())` and checks `scheduler.pace(now:)` every 2 s.
- (from runtime) Integration edits (decision 0054): new `Effectiveness.swift` (`effectiveness`, `checks`); the serve loop runs `OutcomeChecker` (spawned binding servers, read-only `outcome` tool) each pass.
- (from cli-e2e) 2026-11-10: thanks for the cache: the busy seed dropped from 13 to 8 min. What remains is runtime's per-run refolds (asked in runtime's Questions); on the facade side only `RoutineActions.swift:78` (when a run returns routines) and `Improvement.swift:259` still read from seq 1 on the seed path.

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
- 2026-11-09: plan, risk, and `why` are read from each run's recorded `run/result` wire record
  (`RecordedResults`) until runtime folds them into its own events
- 2026-11-09: charter policy rules take an optional `note` (the guardrail in a person's
  words; small AryaCore edit, ARCHITECTURE.md updated) for the approval block
- 2026-11-09: `plan(steward:)` reads runtime's `plan.updated` (decision 0035), falling back
  to recorded results for older homes; time text comes from the workspace clock (`TimeText`)
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
- 2026-11-09: approval content, source, policy rule; run titles; decision why; run now
  without input; 41 AryaTests.
- 2026-11-09: plan, approval risk and why, decision and action why from recorded results;
  42 AryaTests.
- 2026-11-09: approval `policyText` from charter rule notes; 43 AryaTests.
- 2026-11-09: `needsYou()`, `TimeText`/`timeText(_:)`, `event(seq:)` inspector,
  `open(home:environment:ambient:)` for back-dated seeding, plan from `plan.updated`; 47 tests.
- 2026-11-09: approval and run-detail risk from runtime's `action.proposed.risk` (0037), hint as
  fallback; `autonomy:<level>:<risk>` holds get plain `policyText`; 48 tests. `correct(run:)`
  waits on eval's `Corrector.correct(run:)`.
- 2026-11-09: one-call screen reads `improve(steward:) -> ImproveView` and
  `knowledge(steward:) -> KnowledgeView`, sentences written in the facade; 50 tests.
- 2026-11-09: `correct(run:expected:note:by:)` on eval's `Corrector.correct(run:)` and
  `expected(run:choice:)` from the run's recorded result; `whatIf(run:proposal:)`; 52 tests.
- 2026-11-09: autonomy holds read as plain sentences (no tokens); `ApprovalSummary.change`
  (`label: none → billing`, from the last executed value on the target); 54 tests.
- 2026-11-09: `retract(memory:reason:by:)` appends `memory.retracted` (person as actor); the
  note leaves `memory`, `knowledge`, and recall; 56 tests.
- 2026-11-09: `fleet()` for the sidebar; `charterDraft(steward:)` and
  `proposeCharter(steward:draft:baseVersion:)` (draft applied to the live charter, gated
  proposal, never a direct write); `StewardDraft.level` for autonomy; 58 tests.
- 2026-11-10: parity batch: `portfolio()` (by department; charters gain optional `owner` and
  `department`), templates (`templates()`, `createFromTemplate`, five neutral examples in
  `etc/examples/templates`), memory scopes (`remember` shared or per steward, `about:` person
  preferences, `sharedMemory`, `preferences`; shared notes reach every steward's recall),
  `serveStatus()`, `message(steward:text:intent:by:)` with `conversation(steward:)`, and
  `runNow(steward:note:)`; 65 tests.
- 2026-11-10: Paused for the night after 618b1ce (parity batch). Next: `ProposalSummary.impact`
  and `removed` moved from app-outcome's ProposalImpact into the facade, then
  `conversation(steward:person:)` for the connect lane, then the backlog (binding proxy,
  `LedgerCheck` lines, cached `runBook()`).
- 2026-11-10: resumed. Live reads for the work pane (points 1 and 4): `observe(run:)` and
  `observe(steward:)` stream `LiveUpdate{steps, status, stepCount, progress}` from a file watch
  on the ledger (DispatchSource, 1 s fallback poll); `liveRuns()` for the sidebar and status bar.
  `ProposalSummary.impact`, `removed`, and `detail` (ProposalImpact moved from the app, plus
  autonomy raised), measured against the proposal's base version. `conversation(steward:
  person:)`. Next: incremental cached projections (CEO priority).
- 2026-11-10: incremental facade reads (CEO priority, point 4 feel). `FacadeCache` keeps one
  in-memory state per open workspace: run, steward, and approval books (seeded from the disk
  projection cache, so compacted homes work), an action index for approvals, rehearsals,
  casebooks, charter-change times, and the live events (all and per steward). A read stats the
  ledger segments; unchanged means no work, otherwise only new events fold; a broken chain or
  shorter ledger rebuilds. On a 50k-event home warm `approvals()`, `fleet()`, and `needsYou()`
  each run under 20 ms (tested); a second read after N events folds exactly N (tested).
- 2026-11-10: published the cache (d9fadbbf). Then memory, routines, and plan reads on the
  cached state, and seq times by direct lookup: warm on 50k events memory 0.2 ms, knowledge
  0.6 ms, proposals 0.2 ms, plan 8 ms, improve 49 ms (eval reports through `CachedReadSink`).
- 2026-11-10: one source per fact (CEO): `runFacts(run:)`, `liveRuns()`, and `stewardLive(
  steward:)` read the same cached tally (tested to agree). `impact(steward:)` (window
  attribution, rows for separable kinds, confidence from windows, agreement, and check results)
  and `overviewFindings(steward:)`; `findings`, `effectiveness`, `checks` on the cache.
- 2026-11-10: activity, recap, plan, event detail, and conversations read per-steward,
  per-run, and per-seq indexes in the cached state; the 50k-event warm test now holds twelve
  more reads (activity, recap, plan, event, conversation, run, runFacts, ledger page,
  knowledge, memory, impact, overview findings) under 20 ms each.
- 2026-11-10: one serving rule: `serveState()` (scheduler lock held, or a running run's lease
  held), used by `serveStatus()` and `stewardLive`; `LedgerCheck.lines` from the ledger's
  verification report (optional, older JSON decodes).
- 2026-11-10: M3.6 #2 onboarding: `onboardingState(steward:)`, seven ordered steps (systems
  read, people and processes found, context notes, history imported, review progress,
  readiness) from the context, routines, casebook, review queue, and readiness reads.
- 2026-11-10: M3.6 #1 multiple metrics: `Charter.guardrailMetrics` (optional, validated) and
  `metricStatuses(steward:)` (primary then guardrails: value, target, trend, status, movement,
  line); proposal impact counts guardrail metric changes as `metric`.
