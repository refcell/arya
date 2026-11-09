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
- [x] Routines view: names, live version, history, version diff.
- [x] Rehearsals view: per-case results, expected versus actual, correction, Mark ready.
- [x] Metric chart: the steward's outcome metric over time against its target (Swift Charts).
- [x] Charter editor: outcome, metric, guardrails, bindings, triggers, policy, effort; saving
  creates a proposal, never an in-place edit.
- [x] Empty, loading, and error states for every view.

M3, extended (toward `just e2e` driven from the app):
- [x] Changes tab holds the metric chart and the charter editor entry (app-shell routed the
  other tabs in 78c9c17).
- [ ] Run now: start a manual run with an input from the Stream tab (`FeatureWrite.startRun`).
- [ ] Rehearse: start a rehearsal of the live charter on its casebook from the Rehearsals tab.
- [ ] Replay: replay a finished run from the Stream tab and show the divergence report.
- [ ] Steward overview: charter version, readiness, last run, and open approvals at a glance.

M4:
- [ ] Inbox: questions addressed to person bindings, answered with text, in one list.
- [ ] Binding detail in tool calls and actions: which binding served each call (live MCP).
- [ ] Routine action results in the stream, with the sandbox verdict when it blocked a call.

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

- Routines read AryaMemory's `routine.proposed|promoted|retired`. Bodies come from
  `FeatureWorkspace.routineContent` (a default reports them unavailable; the facade call is
  requested in the workspace lane's Questions). The diff is a small LCS line diff in one hunk,
  rendered by `DiffBlock`; it compares the newest version with the live one by default.
- Rehearsals read AryaEval's `rehearsal.started|case.scored|finished`, `case.corrected`, and
  `steward.ready`. Actual results come from the rehearsal run's `run.decision` and
  `action.proposed`; expected ones from the latest correction with `expected`, else
  `FeatureWorkspace.caseExpected` (casebook blob; default unavailable). A correction is text
  only for now and records `case.corrected` plus a `memory.added` note by the person. Mark
  ready is the pane's primary action, offered once per charter version for a finished
  rehearsal that is not a proposal's candidate.

- The metric chart plots per-UTC-day means of `metric.recorded` `{metric, value}` for the
  metric named in the latest `steward.created|charter.updated` charter, the target as a dashed
  rule, and the latest point as the accent dot. `MetricChartView(store:steward:)` is a
  self-contained block the shell can place in the steward overview.

- The charter editor edits a `CharterDraft` (lists as comma-separated text) and records
  `proposal.created` `{id, kind: charter, candidateVersion, title, reason, charter}` with the
  full candidate charter; fields it does not show pass through unchanged. A draft based on a
  version that is no longer live is refused. Policy rules may name actions no binding offers
  (`close: deny` is a guard).

## Questions
- (from app-shell) `FeatureRegistry` now routes Changes, Ledger, Memory, Routines, and
  Rehearsals to your views when a store is wired; metric chart placement is yours. Changes
  shows a primary Accept per proposal, and STYLE.md allows one primary button per pane.
- (from workspace) live on the facade: `routineContent(steward:name:version:)`, `routine(steward:name:version:)`, `routineHistory`, `routines`, `memory(steward:)`, and `caseExpected(casebook:case:) -> Data?` (canonical JSON).

## Log
- 2026-11-09: run stream, feature workspace seam (`FeatureWorkspace`, `PreviewWorkspace`,
  fixtures), interim components, `AryaAppTests` target (c0b8bcd).
- 2026-11-09: approval queue and cards, inline in the stream (db99d35); switched to AryaDesign
  components (d20b497).
- 2026-11-09: ledger table with filters, event detail, and verify (8d48473).
- 2026-11-09: changes tab with gate results, accept, reject, override (c3960b2).
- 2026-11-09: payload readers switched to the runtime's shapes; question cleared (4c7a2d4).
- 2026-11-09: memory view with provenance and retract (f71088f).
- 2026-11-09: routines view with history and version diff (1c91228).
- 2026-11-09: rehearsals view with case review, corrections, and Mark ready (95a77e5).
- 2026-11-09: outcome metric chart against the charter target (857ad11).

- 2026-11-09: charter editor that saves changes as proposals (7451fa6).
