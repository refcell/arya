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
- [x] Ledger table: filter by steward, run, type, actor; event detail; Verify button with result.
- [x] Changes tab: proposals with gate results, accept, reject, override (recorded).
- [x] Memory view: notes with provenance, retract.
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
- Payloads follow the runtime's records (CEO decision): `run.started.trigger` is a string;
  `run.adapter.event` is `{direction, message}` with the raw JSON-RPC line, and only
  `run/event` notifications become steps; `action.proposed` is `{action: ProposedAction,
  disposition, reason}`; `approval.requested` is `{approval, kind, action?, question?, to}`;
  decisions are `{approval, note?}`; `action.executed|failed|rejected` are
  `{action: id, approval?, output|error|reason}`; `run.finished|failed` are `RunEndPayload`.
  The runtime's payload types are internal and the app imports only `Arya`, so the projection
  code reads JSON; switch to typed payloads if the facade exports them.
- The stream builds tool calls from the adapter's `tool_call`/`tool_result` notifications,
  unless the run has `run.tool.call` events (the binding proxy's record), which then win.
- `FeatureStore` is an `ObservableObject` (decision 0020 allows it); transient view state uses `@AryaState` (0021).
- Views use AryaDesign tokens and components (`StepRow`, `StatusBadge`, `PolicyChip`,
  `CodeBlock`, `ApprovalCard`, `EmptyState`, `.aryaPrimary` and friends); a test fails if a
  feature file uses a literal color, font, or small size.

- The ledger table filters by steward, run, type namespace (`run.`) or exact type, and actor
  (`kind:id`); rows are newest first. Verify is a secondary button (the accent stays on
  approvals) and its result stays visible until the next check.

- Changes: `proposal.created` `{id, kind, title, reason, candidateVersion?}`,
  `proposal.gated` with `GateCheckVerdict` fields, and `proposal.accepted|rejected|overridden`
  `{proposal, reason?}`. Accept needs a passing gate; Override is offered only for a failed
  gate and records `proposal.overridden` then `proposal.accepted`, both by the local user.

- Memory reads `memory.added` `{v, note: MemoryNote}` and `memory.retracted`
  `{v, note, reason?}` (AryaMemory's payloads). Retract asks for no reason yet; retracted notes
  stay listed behind "Show retracted" because the ledger keeps them.

## Questions

## Log
- 2026-11-09: run stream, feature workspace seam (`FeatureWorkspace`, `PreviewWorkspace`,
  fixtures), interim components, `AryaAppTests` target (c0b8bcd).
- 2026-11-09: approval queue and cards, inline in the stream (db99d35); switched to AryaDesign
  components (d20b497).
- 2026-11-09: ledger table with filters, event detail, and verify (8d48473).
- 2026-11-09: changes tab with gate results, accept, reject, override (c3960b2).
- 2026-11-09: payload readers switched to the runtime's shapes; question cleared (4c7a2d4).
