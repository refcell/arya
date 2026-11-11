# Lane: runtime

Owns `Sources/AryaRuntime` and `Tests/AryaRuntimeTests`. The `Workspace` facade (`Sources/Arya`,
`Tests/AryaTests`) moved to the [workspace lane](workspace.md).

Goal: **stewards that run reliably and never act without permission.** Steward lifecycle, the
run loop that turns a trigger into ledger events, the policy and approval queue, action
execution, restart recovery, triggers, crews, and the `Workspace` facade the CLI and app use.
Design: [ARCHITECTURE.md](../ARCHITECTURE.md#runs), decisions 0005, 0013, 0014, 0016, 0018.

## Backlog

M1:
- [ ] `Workspace.open(home:ambient:)` in `Arya`: creates the home layout, opens the ledger,
  exposes stewards, runs, approvals, and an event stream. The facade is the only API the CLI and
  app import.
- [x] Steward lifecycle: create (records `steward.created` with the charter), update charter
  (`steward.charter.updated`, version + 1), pause, retire.
- [x] Instruction composer: charter outcome, metric, guardrails, memory snapshot, live routines,
  result schema; deterministic output with a golden test.
- [x] Run loop with the `FakeAdapter`: `run.started` (versions and snapshot), adapter events,
  `run/result` parsing, `run.decision`, `action.proposed`, `run.finished`, failures with
  reasons (`adapter_exited`, `timeout`, `invalid_result`, `budget`).
- [x] Policy: classify each action as `auto`, `ask`, or `deny` with `policy.default` = `ask`;
  table-driven tests.
- [x] Approval queue: `approval.requested`, grant, deny, expiry; actor is the person who decided.
- [x] Action executor protocol with a recording executor for tests; `action.executed` and
  `action.failed` carry output.
- [x] Restart recovery: interrupted runs become `run.failed(interrupted)`; pending approvals are
  intact. Test by killing a run mid-stream.
- [x] `host/ask` handling through the approval queue.

M2:
- [x] `arya binding-proxy`: a stdio MCP server per binding exposing only `read` tools, recording
  `run.tool.call` and `run.tool.result`, and serving recorded results in rehearsal and replay
  (the CLI entry point is wired by cli-e2e).
- [x] Triggers: manual, interval, message; the scheduler holds `scheduler.lock`;
  only ready, unpaused stewards take live triggers.
- [ ] Calendar triggers: core `Trigger` has no calendar kind yet; add it with core first.
- [x] Crews: delegations become child runs bounded by `crew.maxParallel`, then one join run.
- [x] Budgets: `maxTurns`, `timeoutSeconds`, `maxCostMicros` enforced with `run/stop`.
- [ ] Wire `GateChecking` to `AryaEval` in the facade; charter and routine changes go live only
  through it.
- [ ] Facade API for eval, memory, and routines that the CLI and app need.

M4:
- [x] Live MCP executor for binding actions; person bindings (local inbox).
- [x] `arya serve` loop (`RuntimeService`) with an `ApprovalNotifier` hook; the login item and
  posting notifications belong to the CLI and app.

## Decisions

- Facade first, backed by nothing: `Workspace` publishes its full M1 signature now; calls whose
  backing module has not landed throw `WorkspaceError.unavailable(call)`. Ids are `String` in
  the facade so the CLI and app never import lower modules; read models are facade-owned
  values (`StewardSummary`, `RunSummary`, `ApprovalSummary`, `LedgerEntry`, `LedgerCheck`) with
  status enums nested to avoid name clashes.
- No interim copies of core types (JSON value, ambient, event store) in the runtime: pure
  pieces first, and storage behind a runtime-owned `EventSink` protocol with an in-memory
  double until `AryaLedger` lands.
- Policy order: structural refusals first (`empty_kind`, `no_binding`,
  `unknown_binding:<id>`, `not_allowed:<binding>.<kind>` are always `deny`, because arya could
  not carry the action out), then the first rule for the kind, then `policy.default` (`ask`).
  Action kind `routine` needs no binding. The verdict's `reason` is recorded with the
  disposition.
- The instruction composer takes plain `InstructionInputs`, not a charter, so memory and
  routine lanes can feed it without a dependency; guardrails and bindings keep charter order,
  memory keeps snapshot order, routines sort by name.
- Run phases: `started → running → disposing(status) → finished(status)`, with `fail(reason)`
  from any live phase; terminal phases reject every input. Adds failure reason
  `adapter_failed` for `run/result` with `status: failed` or a harness error. The phase input
  type is `RunPhaseInput` (`AryaAdapters` already exports `RunInput`).
- Policy rules may name a `binding`; such a rule matches only actions through that binding and
  records reason `rule:<binding>.<kind>`.
- Approvals: payloads `approval.requested {approval, kind, action|question, to, expiresAt?}`
  and `approval.granted|denied|expired {approval, note?}`. The deciding person is the event
  actor; expiry is `system`. The projection keeps the first decision and ignores later ones, so
  two processes racing to decide cannot flip an approval. Any person may decide (single user);
  `to` is advisory.
- Steward lifecycle on core `Charter`: create validates and rejects duplicates; updates bump the
  version and keep readiness (gating arrives in M2); pause needs `active`, resume needs
  `paused`, retire needs not `retired`. Adds `steward.resumed` (decision 0022).
  `ActionDisposition` is now an alias of core `PolicyDecision`; `ActionPolicy(charter:)` and
  `InstructionInputs(charter:)` map a charter.
- Actions: `action.proposed {action, disposition, reason}` (actor: steward), then
  `action.executed {action, approval?, output}`, `action.failed {action, approval?, error,
  output?}`, or `action.rejected {action, approval?, reason}` (actor: system). `action` in the
  outcome payloads is the result-local action id; the envelope's `run` makes it unique.
  Executors never throw; failures are outcomes so they are always recorded. A granted action
  executes with the steward's live charter binding; denied or expired approvals record
  `action.rejected` with reason `approval_denied` / `approval_expired`.
- Run loop: `run.started {trigger, input, parent?, charterVersion, adapter, effort,
  instructions, memory, routines, rehearsal}` (actor: whoever started it), every JSON-RPC line
  as `run.adapter.event {direction, message}` (actor: adapter, id = run id; a non-JSON line is
  stored as `{raw}`), one `run.decision` per decision (the decision object), dispositions,
  then `run.finished {status, summary, costMicros, decisions, actions, leak}` or `run.failed
  {reason, detail, costMicros, leak}` (actor: system). `run/cost` is asked after the result
  and before `shutdown`. Protocol errors are recorded through the wire and otherwise ignored.
  `run.tools` is empty until the binding proxy lands (M2). `charterVersion` 0 means a candidate charter under rehearsal.
- `host/ask` in a live run becomes a `question` approval addressed to `to` (default `local`)
  with `expiresAt` = now + `limits.timeoutSeconds` (ambient time). The run polls the ledger
  every `questionPoll` (250 ms) until it is granted (answer = the grant's note), denied
  (`null`), or expired (`null`, recorded by the runtime). Rehearsal answers `null` and asks no
  one. The connection's wall-clock idle timeout can still stop a run whose question waits
  longer than `timeoutSeconds`; see the adapters lane question.
- The run driver type is `RunEngine` (not `RunLoop`, which Foundation exports). Run projection
  is `RunBook` with `RunRecord.Status` nested (adapters export `RunStatus`).
- Restart recovery: every run holds a `RunLease` while its process drives it. `FileRunLeases`
  `flock`s `<dir>/<run>.lock` (the kernel frees it when the process dies); the facade should
  use `<home>/cache/runs` and share one leases object between `RunEngine` and `RunRecovery`.
  `RunRecovery.recover()` records `run.failed {reason: interrupted}` for open runs nobody
  holds, so a run the CLI is driving is never failed by the app starting. Re-queuing scheduled
  runs comes with the scheduler.
- Payloads for `run.*`, `action.*`, and `approval.*` are `AryaLedger`'s typed structs
  (decision 0024), `ProposedAction` is core's. `run.finished` carries `cost` and `counts`;
  `leak` is no longer on the ledger (rehearsal records it on `rehearsal.case.scored`).
  `RunRequest.rehearsal` (`RehearsalTag`: rehearsal, case, sample) fills `run.started`; a run
  counts as a rehearsal in `RunBook` when it has a tag or trigger `case`.
- Rehearsal mode (`RunMode.rehearsal(context)`): dispositions are recorded as
  `action.proposed` only. Until the binding proxy serves reads, a leak is a `tool_call` event
  whose `(tool, input)` has no entry in `context.toolResults`.
- `LedgerEventSink` is the real `EventSink`: appends through `LedgerStore`, reads through
  `LedgerReader`. `RuntimeEvent`/`RuntimeActor` stay as thin views so eval and the facade keep
  compiling; `RuntimeActor.adapter(profile)` carries the adapter profile, as the ledger does.
- `metric.recorded` (decision 0030): the runtime writes one per measurement of a live run,
  after `run.decision`; the payload type `MetricRecorded` lives in the runtime.
- Budgets are enforced by the runtime too, not only passed to the adapter: a turn is one
  assistant `message` event; after each turn the runtime reads `run/cost`. Past `maxTurns` or
  `maxCostMicros` it sends `run/stop {reason: budget}`, waits for the adapter's last word, and
  records `run.failed {reason: budget, detail: max_turns|max_cost_micros: N > limit}`. A
  wall-clock deadline of `timeoutSeconds` sends `run/stop {reason: timeout}` and fails the run
  `timeout`. A result that arrives within budget finishes normally even if its final cost is
  over (the work is done; the cost is on `run.finished`).
- Scheduling is a pure plan over the books (`SchedulePlan.due`): a steward that takes live
  triggers and has an interval trigger (shortest wins) is due when it has no open live run and
  never ran on a schedule, last started a scheduled run one interval ago, or its last scheduled
  run failed `interrupted` (the restart re-queue). Manual and message runs do not move the
  schedule. `Scheduler` (an actor) fires due runs in the background; `deliver` starts a
  message run when a `message` trigger matches the sender (a person binding id), with that
  person as actor. `SchedulerLock` flocks `<home>/scheduler.lock`; the facade takes it before
  creating a `Scheduler`.
- Crews: `RunEngine.run` fans out a live top-level run's `delegations` before returning
  (`RunOutcome.crew`). A child keeps the parent's trigger kind and charter, has `parent` set,
  and records its actions as `action.proposed` only. The `join` run's input is canonical JSON
  `{children: [{delegation, title, run, status, summary?, decisions, actions}]}`, where
  `status` is `completed`, `stopped`, or `failed:<reason>`; failed children are reported, not
  retried. Children, joins, and rehearsals never fan out (depth 1). `SchedulePlan` looks only
  at top-level runs.
- Memory around a run: `run.started` records the memory snapshot and live routine versions
  from `RunPreparation.context` (the case tag for tagged rehearsals), and the instructions show
  those notes and routines. A live run's `run/result.memories` go through
  `MemoryIntake.notes` and land as `memory.added` (actor: the steward) after `run.decision`.
  Wire lines are recorded with adapters' `WireRecord.ledgerPayload`.
- Books adopt `LedgerProjection` with `catchUp` and `ProjectionCache` (decision 0028): done
  by the ledger lane. `RuntimeBook` (BookCache.swift) and `sink.book(_:)` serve
  `StewardBook`/`RunBook`/`ApprovalBook` from `cache/runtime.*.v1.json` over the real ledger
  and fold every event over other sinks. Bump a book's `cacheName` suffix whenever its fold
  or coded shape changes. One intended difference: `book()` reads only lines after the cached
  position, so tampering before it no longer throws there (`verify` still reports it).
- Routine policy (decision 0032): rules `routine:<name>@<version>` decide a version; a bare
  `routine:<name>` can only deny; everything else asks. The dispatcher gets live routine
  versions from the run's memory context (`dispose(..., routines:)`).
- Binding proxy core: `BindingProxy` (actor) answers MCP `initialize`, `ping`, `tools/list`,
  and `tools/call` over newline-delimited JSON-RPC. It lists only `binding.read` tools and
  refuses others with `-32602`, unrecorded. Calls are recorded as `run.tool.call
  {id: <binding>:<rpc id>, binding, tool, input}` and `run.tool.result {id, output, isError}`
  (actor: system). `ToolSource.live` forwards to a `ToolUpstream`. `.recorded` answers from
  `RecordedToolResult`s whose tool is `<binding>.<tool>` (or bare) with an equal input; a miss
  answers `isError` and sets `leak`.
- Binding proxy wiring: `RunEngine(proxy: BindingProxyLaunch(command:args:))` gives each run
  one `run/start.tools` server per MCP binding with read tools. The args are the launch args
  plus `--steward --run --binding`, and in rehearsal `--recorded <workdir>/tool-results.json`
  (the case's recordings, written by the runtime). The proxy process uses
  `BindingProxyArguments(parsing:)`, then `BindingProxyHost.proxy(_:sink:)` (binding from the
  live charter; live servers through `ProcessToolUpstream`), then `serveStandardIO`.
  `ToolRecordings.from(events, run:)` turns a run's tool calls into recordings for replay.
- `BindingActionExecutor` (M4): an MCP binding's action calls the tool named by its kind with
  `params` + `target` on a fresh server (closed after); a person binding's action succeeds
  with output `{inbox, channel, target?, params?}`, which is the local inbox entry; `routine`
  actions go to an injected routine executor. The facade swaps it in for `RecordingExecutor`.
- `RuntimeService` is the process holding `scheduler.lock`: `run(every:)` recovers, then
  ticks. Each tick expires due approvals, fires due interval triggers, and announces newly
  pending approvals once to an `ApprovalNotifier`. `deliver` forwards message triggers.
- Plans (decision 0035): `PlanBook.plan(in: RunResult)` maps adapters' `plan` steps;
  `PlanBook` projects the current plan per steward from `plan.updated {items, reason?}`.
- Risk and autonomy (decision 0037): `ActionPolicy(charter:)` reads `charter.autonomy` and
  `policy.risk`; `PolicyVerdict` carries `risk` and `autonomy`, written onto
  `action.proposed`. Small additive edits in `AryaCore` (types, charter and policy fields,
  `ProposedAction.risk`) and `AryaLedger` (`ActionProposed.risk/autonomy`).
- Inbox (decision 0039): `Inbox.post` (also `RuntimeService.inbox`) and `InboxBook` in
  `Inbox.swift`; `Scheduler.deliver` takes run input attachments.
- Sandbox (decision 0040): `Sandbox`, `SandboxedRoutineRunner` in `Sandbox.swift`;
  `RunEngine(sandbox:)`; `CharterBinding.network` (core) and `RunStarted.sandbox` (ledger)
  are small additive edits; `Workspace` wiring defaults to sandboxed routines. Harnesses get
  `run/start.sandbox` when the adapter reports `os`; `run.sandboxed {harness}` records it.
- Relays (decision 0042): `CharterBinding.via` (core); `Inbox.pull` for inbound,
  `ExecutionRequest.relay` and `BindingActionExecutor` for outbound;
  `RuntimeService(relays:)` pulls every relay each tick (errors in `ServiceTick.relayErrors`).
- Crew budgets (decision 0043): `CrewBudget`, `RunDelegated` in `Crews.swift`; additive
  `RunResult.Delegation` fields (adapters), `Crew.adapters` (core), and a replay line in
  `RunReplayer` (eval) so crew children replay with their recorded budget.
- Re-planning (decision 0046): `Replans.swift` (`Setback`, `RunEngine.replan`,
  `ReplanRefused`); `Scheduler.replan` for setbacks found after a run; the service tick
  re-plans expired approvals. Integration edits: `Workspace.approve/deny`, the replayer, and
  additive `replan` input kinds (adapters, ledger) and `Limits.maxReplans` (core).

## Questions

- The eval `CaseRunner`, the cli-e2e facade additions, app-shell's effort read and write, and
  memory's routine wiring (decision 0025) moved to the [workspace lane](workspace.md) with the
  facade. For decision 0026 the facade
  appends `steward.effort.set {effort}` (actor: the person); proposed default: `StewardBook`
  folds it into `charter.effort` without bumping the version, so the next run records the
  effort it used in `run.started`. The workspace lane landed that fold as a small integration
  edit in `Stewards.swift`.
- (from adapters) OS sandbox for harnesses: `run/start.sandbox` (`SandboxRequest`: SBPL `profile` + `params`) is honored by adapters reporting capability `sandbox: "os"` (the exec adapter on any Mac with `/usr/bin/sandbox-exec`); others reject it with `-32002`. Suggested default: `OSSandbox.confiningWrites(to: workdir, network: .allowed)` when the adapter reports `os`. Routine sandboxing (0031) can reuse `OSSandbox.wrap(_:in:)` around the routine runner's command.
- (from adapters) Sandbox network per the CEO: pass `OSSandbox.confiningWrites(to: workdir, extraWritablePaths: [], network: .denied)` unless a charter binding allows network (proposed: an optional binding field such as `network: "allowed"`, owned by core), then `.allowed`; the exec adapter reports blocked writes and connections as one `error` event sentence starting "The sandbox blocked the agent".
- (from eval) FYI: added `RunRequest.crew` (`.skip` for replay) and public `runCrew` keeping mode/tag.
- (from governance) Integration edit (G2, CEO-assigned trust/control lane): `RunDriver` watches for `run.abort.requested` (ledger-owned payload) and stops the run; new `RunFailureReason.aborted`. See ledger.md decision "(G2 abort)". Re-planning or stream changes there: keep the `aborted` checks in `.result`, `.timedOut`, `.exited`, and `ask`.
- (from connect) Binding servers need their secret: when starting a binding's MCP server
  (`BindingActionExecutor.spawn`, the binding proxy), add `ARYA_CREDENTIAL` from a credential
  provider closure `(bindingID) -> String?` passed in by the workspace
  (`ConnectionCredential.environment` in `Sources/Arya/Connections.swift`); never record it.
- (from governance, resolved 2026-11-10: `LedgerReader` now reads archived segments first, so no change is needed here) Retention (G3) cannot archive old segments while runtime folds read `sink.events(from: 1)` (RunEngine, RunDriver plan/memory, Inbox, Scheduler): they would lose stewards, memory, and plans. Could those go through `sink.book(_:)`/`ProjectionCache` (which seeds from checkpoints on a compacted ledger)? Then `applyRetention` can move segments.
- (from workspace) Integration edits: `MemoryScope.shared` (`st_shared`) notes join every run's recall (up to 4, after the steward's own) in `MemoryView.context`; `SchedulerLock.isHeld(home:)`; `Inbox.record` (no run), `Inbox.localSender` (`local`, channel `app`), and `Inbox.runInput`, with `post` = record + deliver.
- (from eval) FYI: rehearsals now show `CaseContext.plan`, not the live plan; keep that for re-planning.
- (from adapters) Re 0049 and 0051: adopted `tool_output` (plus optional `stream`: `stdout`/`stderr`) instead of a second kind, and kept your `pace` and `ARYA_FAKE_PACE_MS`; fake scripts now also have `stream` and `pauseMs` steps (played only at a demo pace) plus `diff` and `progress` events. The triage, refunds, and digest scripts use them, so paced demo runs show search hits, order lookups, streamed command output, and routine diffs. Exec streaming of command output: neither stream-json nor codex-json emits output before the result; codex commands now show as running from `item.started`.
- (from adapters) FYI: `run.step.finished.millis` is wall time, so replays diverged on it; eval's `Canonicalizer` now ignores it (integration edit). Any other clock-derived payload field needs the same entry in `Canonicalizer.durations`.
- (from workspace) the facade's live view reads `run.step.*` and dedupes against the adapter's wire tool events by call id; if you ever stop recording the wire tool events, nothing breaks.
- (from cli-e2e) 2026-11-10: the busy demo seed (690 runs) still takes 8 min after workspace's cache; a sample shows each run reading the whole ledger: `RunEngine.swift:230` (`events(from: 1)`) and `:242` (`PlanBook` refold), `RunDriver.swift:275` (`PlanBook`) and `:292` (`MemoryView`), and `Inbox.swift:231` (`MemoryView`) per message. Could these read `BookCache.book(_:)` (or an incremental plan and memory view)? That would make a run O(new events) and the seed about 1-2 min.
- (from workspace) tiny AryaCore edit: `Charter.guardrailMetrics: [Metric]?` (omitted when nil, so existing charter hashes hold; validation: named, distinct from the primary). Runs already record any measurement name; please name the guardrail metrics in the run brief so adapters measure them too.
- (from workspace) tiny AryaCore edit: `Metric.windowDays: Int?` (evaluation window, 1-366, omitted when nil so charter hashes hold; default 7 in the facade).
- (from workspace) `onboarding(steward:)` (Onboard.swift) reads the cached state instead of `sink.events(from: 1)`; onboardingState folds its summary in.

## Log
- 2026-11-09 (ledger lane): runtime books on `ProjectionCache` via `RuntimeBook`; behavior
  identical (test `cachedBooksMatchAFullFold`), runtime, ledger, and facade tests green.

- 2026-11-09: policy classifier, run phases, instruction composer, and the `Workspace` facade
  API (stubs throwing `unavailable`) landed; cli-e2e and app lanes can code against
  `Sources/Arya` (0d5c02b)
- 2026-11-09: `EventSink` seam with an in-memory double and the approval queue (9d8e381)
- 2026-11-09: steward lifecycle on core `Charter`; decision 0022 (19215d3)
- 2026-11-09: action executor protocol, `RecordingExecutor`, and `ActionDispatcher` (ce6ab45)
- 2026-11-09: run loop over `Adapter` with live and rehearsal modes, failure reasons, and wire
  recording; the workspace lane can build `CaseRunner` on `RunEngine.run` with
  `RunMode.rehearsal(case.context)` (bc170c7)
- 2026-11-09: `host/ask` through the approval queue; adapters lane question on idle timeouts
  (0d7d127)
- 2026-11-09: `RunBook`, run leases, and restart recovery (`RunRecovery`); renamed `RunLoop`
  to `RunEngine` and fixed the workspace lane's use (bb35150)
- 2026-11-09: run, action, and approval payloads are the ledger's typed structs (d190a54);
  rehearsal runs carry a `RehearsalTag` (d0d97f5)
- 2026-11-09: `LedgerEventSink` over the real ledger; end-to-end run and restart on a temp home
- 2026-11-09: `metric.recorded` from live-run measurements (decision 0030)
- 2026-11-09: budgets: turns, cost, and wall-clock deadline enforced with `run/stop`
- 2026-11-09: triggers and scheduler (`SchedulePlan`, `Scheduler`, `SchedulerLock`); interrupted scheduled runs re-queue
- 2026-11-09: crews: child runs bounded by `crew.maxParallel`, then one join run
- 2026-11-09: memory snapshot and routines in `run.started`, `memory.added` from live runs, wire lines via `WireRecord.ledgerPayload`
- 2026-11-09: routine approval per name and version (decision 0032)
- 2026-11-09: binding proxy core (`BindingProxy`, `ToolUpstream`, recorded source)
- 2026-11-09: binding proxy process upstream, host, launch wiring, and ledger recordings for replay
- 2026-11-09: `BindingActionExecutor` for MCP and person bindings
- 2026-11-09: `RuntimeService` (serve loop) with approval announcements
- 2026-11-09: steward plans: `plan.updated`, `PlanBook`, plan in instructions (decision 0035)
- 2026-11-09: risk levels and per-steward autonomy on charters and proposals (decision 0037)
- 2026-11-09: `why` on `run.decision` and `action.proposed` actions, adapter risk hints kept
- 2026-11-09: local inbox: messages, corrections as memory, message runs (decision 0039)
- 2026-11-09: routines and binding servers sandboxed, recorded on `run.started` (decision 0040)
- 2026-11-09: schedule status: `SchedulePlan.status` / `Scheduler.status` (next wake, last N outcomes)
- 2026-11-09: harness sandbox via `run/start.sandbox` for `os` adapters; `run.sandboxed`
- 2026-11-09: integration fix in `RunReplayer`: replays sandbox when the recorded run did
- 2026-11-09: email and chat relays for person bindings (decision 0042)
- 2026-11-09: `RuntimeService` pulls relay bindings each tick when given `relays`
- 2026-11-09: default risk by action kind (`Risk.defaults`), `Workspace.risk` read (0037)
- 2026-11-09: crew children with bounded adapter, effort, and limits; `run.delegated` (0043)
- 2026-11-09: re-planning after failed, denied, or expired actions, bounded per chain (0046)
- 2026-11-09: steward context read model (`StewardContext`, `Workspace.context`) (0047)
- 2026-11-09: Paused for the night after publishing re-planning (0046) and steward context (0047). Next: in-run `host/delegate` through the crew path (replace the refusal in `RunDriver`'s `.delegate` case with a bounded child via `CrewBudget`, record `run.delegated`, answer `HostDelegateResult`; replay answers from the recording), then learn-from-results, proactive findings, and onboard runs.
- 2026-11-10: live step events (`run.step.started`/`output`/`finished`, chunked, long output in blobs) (0049). Moves point 4 (live feel) at the source; the app view is app-views'.
- 2026-11-10: report runs (trigger `report`, one `send` per relay person through the dispatcher, no re-plan) per the CEO (0050); `sendReport` uses them for relay recipients.
- 2026-11-10: demo pace (0051): `DemoPacer` + `Scheduler.pace`, `arya serve --demo-pace`, fake adapter `ARYA_FAKE_PACE_MS`, `demo.sh --live`. Live check on the seeded demo home (6 min): paced runs alternated st_triage/st_refunds every 25-40 s, ~8 s each, each with `run.step.started/output/finished`. Visual check: pending (`just snapshot` was queued behind the CI slots; retake after the queue drains). Moves points 4 (live feel) and 5 (busy home).
- 2026-11-10: in-run `host/delegate` runs a real child through the crew path (budget, proposals only, `run.delegated`, depth 1, `maxParallel`), answered when it ends; replay answers from the recording (0053). Fake-adapter tests in runtime and eval.
- 2026-11-10: learn from results (0054): follow-up `outcome` checks → `action.checked`, per-kind effectiveness with windowed metric credit, "What has worked" in live instructions, facade `effectiveness`/`checks`.
- 2026-11-10: proactive findings (0055): `findings` in results → `finding.raised` once while open, `finding.resolved` by a person, facade `findings`/`resolveFinding`.
- 2026-11-10: drafts (0056, CEO review #10): `ExecutionOutcome.drafted` → `action.executed` with `dryRun: true`; skipped by follow-ups and credit; facade shows "Drafted, not sent".
- 2026-11-10: run start O(new events) (0057, CEO): `StartCache` on the engine (plans, memory, findings, effects by last seq), incremental `EffectFold`, ledger tail reads from line marks; warm start on 50k events about 5 ms (probe, `ARYA_PERF=1`).
- 2026-11-10: per-message and per-pass reads (0057): inbox correction check reads the cached memory; scheduler tick/status read the cached steward and run books; demo pace reads the ledger only when a run is due. Test: handling message N folds only new events.
- 2026-11-10: timings after 1af0910b (plus 7a816d35): warm run start on a 50,000-event home 4.9 ms (target 10 ms; was 52 ms), parts: steward book 4.0 ms, start state 2.3 ms, ledger tail 2.1 ms (`ARYA_PERF=1` probe, debug build). Busy demo seed (`arya-demo`, 11 stewards, 693 runs, 17,481 events): 74.5 s wall at load 33-46 (target under 2 min; cli-e2e measured 8 min before).
- 2026-11-10: self-onboarding (0059): onboard runs read `directory`/`process` bindings into memory notes with provenance, `onboard.read`/`onboard.completed`; automatic before a new steward's first live run; facade `onboard`/`onboarding`; `arya steward onboard`.
- 2026-11-10: per-person memory (0061): `person:<id>` notes recalled only for runs acting for that person (sender, named bindings, `person:<id>` in the input), inbox corrections tagged with the sender, facade `personMemory`.
- 2026-11-10: shared routines (0062): one version per content hash across stewards, followers and upgrades (`RoutineUpgrades`), upgrade is a gated adoption; facade `routineUses`, `routineUpgrades`, `upgradeRoutine`.
- 2026-11-10: onboarding reads `history` (0063): up to 500 past records summarized into who-handles-what, routing, outcome, and resolution notes with provenance; `records` on read/completed/summary.
- 2026-11-10: grants enforced (0064): `use` on actions taken for a person (rejected `access:use`, finding raised), `approve` on approval decisions (`approval.refused`, rule `grant:approve`); `AccessSource` via `Wiring.access`, data and `view` with workspace.
- 2026-11-10: runtime features without an app surface (no use found in `Sources/AryaApp`), for routing:
  per-person memory (`personMemory`, `preferences`, 0061); routine uses and upgrades
  (`routineUses`, `routineUpgrades`, `upgradeRoutine`, 0062); history counts from onboarding
  (`OnboardSummary.records`, 0063); follow-up checks per action (`checks(steward:)`,
  `CheckSummary`, 0054); re-plan runs and why (0046, input kind `replan`); grant refusals and
  approve refusals (0064). Findings, drafts, onboarding, steps, reports, and delegations are shown.
- 2026-11-10: grant store (0065): `access.*` events, `AccessBook`, gated changes (owner or approve on `*`) with undo, `access.refused` audit event, facade `access()` and writes; Settings ▸ Access next.
- 2026-11-10: Settings ▸ Access (`Features/Access`): status and last change with Undo, Grant… form (who, may, on), Grants by resource with Revoke, Teams with New team…/Edit/Disband, Refused list; states `access`, `access-refusals`; Settings tab hook asked of app-shell.
- Visual check (`just snapshot access access-refusals`, demo home): Access title, "Enforced · 2 grants · 1 team", last change with Undo, Grants by resource with pills and Revoke, Refused rows with time, cross, plain reason, steward and level; one orange Grant…. The demo home has no refusals yet, so that list shows fixtures; the space below short lists stays empty.
- 2026-11-11: Access in words, per review VC38b: "Jules can approve everything", "Sam can't refund on Billing", steward and connection names, no ids (facade adds optional `kind`/`grant`/`team`/`undone` on the last change and `resources` on refusals); Access is a main-window page (Go ▸ Access) with an inspector (levels, who can change access); snapshot state `access-window`. Written while builds are paused; build, snapshot, Visual check, and publish when resumed.
- Visual check (`just snapshot access access-refusals access-window`, demo home, dark and light): "Jules can approve everything · You · now" with Undo; grants under "Everything" and "Alerts connection" with names (Jules, Support (team)); refusals read "Sam can't refund on Billing" and "Sam can't approve reply for Support inbox triage" with steward names; access-window shows sidebar, Access in the stream, and the Access inspector (levels, who can change access, enforced). The window loads the demo home itself, which has no refusals yet, so its Refused tab is empty.
- 2026-11-11 VC39 (layout part): the Access window page shows Grants beside Teams and Refused (no tabs), refusal rows drop the steward column (the sentence names it), team rows put members under the name, the inspector lists recent changes (facade `changes`, newest 12). `access` and `access-refusals` are Settings-size parts; `access-window` reports to empty.tsv. Seeding real teams, grants, and refusals waits on workspace's cost-pricing seeder change.
