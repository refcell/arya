# Lane: runtime

Owns `Sources/AryaRuntime`, `Sources/Arya`, `Tests/AryaRuntimeTests`, and `Tests/AryaTests`.

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
- [ ] Restart recovery: interrupted runs become `run.failed(interrupted)`; pending approvals are
  intact. Test by killing a run mid-stream.
- [ ] `host/ask` handling through the approval queue.

M2:
- [ ] `arya binding-proxy`: a stdio MCP server per binding exposing only `read` tools, recording
  `run.tool.call` and `run.tool.result`, and serving recorded results in rehearsal and replay
  (the CLI entry point is wired by cli-e2e).
- [ ] Triggers: manual, interval, calendar, message; the scheduler holds `scheduler.lock`;
  only ready, unpaused stewards take live triggers.
- [ ] Crews: delegations become child runs bounded by `crew.maxParallel`, then one join run.
- [ ] Budgets: `maxTurns`, `timeoutSeconds`, `maxCostMicros` enforced with `run/stop`.
- [ ] Wire `GateChecking` to `AryaEval` in the facade; charter and routine changes go live only
  through it.
- [ ] Facade API for eval, memory, and routines that the CLI and app need.

M4:
- [ ] Live MCP executor for binding actions; person bindings (local inbox).
- [ ] `arya serve` loop as a login item; approval notifications.

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
  `run.tools` is empty until the binding proxy lands (M2). `host/ask` is answered `null` until
  its backlog item lands. `charterVersion` 0 means a candidate charter under rehearsal.
- Rehearsal mode (`RunMode.rehearsal(context)`): dispositions are recorded as
  `action.proposed` only. Until the binding proxy serves reads, a leak is a `tool_call` event
  whose `(tool, input)` has no entry in `context.toolResults`.

## Questions

- From eval (integration need): rehearsal needs the runtime to implement
  `AryaEval.CaseRunner.run(_:)`: one run with trigger kind `case` for `request.caseItem`, tool
  reads answered from its `context.toolResults`, no action executed, returning the run id, the
  result shaped like the case's `expected`, and `leak`. Eval cannot import the runtime's types
  the other way, so the facade wires a runtime-backed `CaseRunner` into `CasebookRehearser`.
- (from cli-e2e) The CLI needs from `Workspace`: the live charter for `arya steward show`
  (proposed `charter(_ id:) -> Data`), a run detail with decisions and per-action dispositions
  (proposed `run(_ id:) -> RunDetail`), and the M2 calls behind `casebook import`, `rehearse`,
  `correct`, `ready`, `metrics`, and `replay`. Until then `arya run` reads the run's ledger
  entries.
- (from app-shell) The app's header effort selector needs a facade read of each steward's
  charter effort and a write that records it (or a proposal). Until then the app shows
  `medium` and reports the write as unavailable.

## Log

- 2026-11-09: policy classifier, run phases, instruction composer, and the `Workspace` facade
  API (stubs throwing `unavailable`) landed; cli-e2e and app lanes can code against
  `Sources/Arya` (0d5c02b)
- 2026-11-09: `EventSink` seam with an in-memory double and the approval queue (9d8e381)
- 2026-11-09: steward lifecycle on core `Charter`; decision 0022 (19215d3)
- 2026-11-09: action executor protocol, `RecordingExecutor`, and `ActionDispatcher` (ce6ab45)
