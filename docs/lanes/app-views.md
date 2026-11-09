# Lane: app-views

Owns `Sources/AryaApp/Features`.

Goal: **every part of a steward's life visible and correctable from the app.** The feature views
that live inside the shell: run stream, approvals, ledger, memory, routines, rehearsals,
metrics, and the charter editor. All visuals come from `AryaDesign`; no raw colors or font sizes
([STYLE.md](../STYLE.md)).

## Backlog

M3 (start now against the app-shell stub workspace):
- [x] Run stream: messages, tool calls and results, decisions, proposed actions, status, live.
- [x] Approval queue and approval cards: action, rationale, target, approve and deny with the
  local user recorded as actor.
- [ ] Ledger table: filter by steward, run, type, actor; event detail; Verify button with result.
- [ ] Changes tab: proposals with gate results, accept, reject, override (recorded).
- [ ] Memory view: notes with provenance, retract.
- [ ] Routines view: names, live version, history, version diff.
- [ ] Rehearsals view: per-case results, expected versus actual, correction, Mark ready.
- [ ] Metric chart: the steward's outcome metric over time against its target (Swift Charts).
- [ ] Charter editor: outcome, metric, guardrails, bindings, triggers, policy, effort; saving
  creates a proposal, never an in-place edit.
- [ ] Empty, loading, and error states for every view.

## Decisions

- Approval cards appear in the queue (all stewards, or one) and inline in the run stream for
  actions waiting on a person. The primary label names the effect ("Approve and assign"). Deny
  records an empty reason for now; a reason field follows with the shared text-field
  component. Action ids are matched within their run, since ids such as `a1` repeat per run.

- Feature views read events through local seams in `Features/Support`: `FeatureEvent` (the
  ledger envelope with a `FeatureJSON` payload), `FeatureWorkspace` (events, `record` of a
  `FeatureWrite`, `verify`, `changes`), and `PreviewWorkspace` with `PreviewFixtures` (a generic
  issue-triage steward). The facade will conform to the protocol, or the seam is deleted once
  it offers the same calls. Every write is attributed to `FeatureActor.localUser`.
- Payload field names follow PROTOCOL.md where it defines them (`run/event`, `run/result`).
  Where the ledger lane has not published payloads yet, views assume: `run.tool.call`
  `{id, tool, input}`, `run.tool.result` `{id, output, isError}`, `action.proposed`
  `{id, kind, target, policy, rationale, summary?}`, `approval.requested` `{id, action}`,
  `approval.granted|denied` `{approval, reason?}`, `action.executed|failed|rejected`
  `{action, output|error|rule}`. Projection code is the only place that reads them.
- The stream shows tool calls from `run.tool.*` (the binding proxy's record) and skips adapter
  `tool_call`/`tool_result` notifications, which would duplicate them.
- `FeatureStore` is an `ObservableObject` (decision 0020 allows it); transient view state uses `@AryaState` (0021).
- Views use AryaDesign tokens and components (`StepRow`, `StatusBadge`, `PolicyChip`,
  `CodeBlock`, `ApprovalCard`, `EmptyState`, `.aryaPrimary` and friends); a test fails if a
  feature file uses a literal color, font, or small size.

## Questions

- (from cli-e2e) `RunStreamModel` reads `approval.requested` as `{id, action: "<id>"}`, but the
  runtime decision records `{approval, kind, action: {…ProposedAction}}`; the CLI's `RunDigest`
  accepts both.

## Log
- 2026-11-09: run stream, feature workspace seam (`FeatureWorkspace`, `PreviewWorkspace`,
  fixtures), interim components, `AryaAppTests` target (c0b8bcd).
