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
- [ ] Steward lifecycle: create (records `steward.created` with the charter), update charter
  (`steward.charter.updated`, version + 1), pause, retire.
- [ ] Instruction composer: charter outcome, metric, guardrails, memory snapshot, live routines,
  result schema; deterministic output with a golden test.
- [ ] Run loop with the `FakeAdapter`: `run.started` (versions and snapshot), adapter events,
  `run/result` parsing, `run.decision`, `action.proposed`, `run.finished`, failures with
  reasons (`adapter_exited`, `timeout`, `invalid_result`, `budget`).
- [ ] Policy: classify each action as `auto`, `ask`, or `deny` with `policy.default` = `ask`;
  table-driven tests.
- [ ] Approval queue: `approval.requested`, grant, deny, expiry; actor is the person who decided.
- [ ] Action executor protocol with a recording executor for tests; `action.executed` and
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

## Questions

## Log
