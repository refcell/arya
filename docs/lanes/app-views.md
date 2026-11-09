# Lane: app-views

Owns `Sources/AryaApp/Features`.

Goal: **every part of a steward's life visible and correctable from the app.** The feature views
that live inside the shell: run stream, approvals, ledger, memory, routines, rehearsals,
metrics, and the charter editor. All visuals come from `AryaDesign`; no raw colors or font sizes
([STYLE.md](../STYLE.md)).

## Backlog

Priority reset (visual target: dense, dark-first, low-chrome workspace; tokens from app-shell):
- [x] Stream as a split pane: conversation, reasoning, and decisions as compact rows on the
  left; tool calls, results, actions, and diffs as compact cards on the right with mono
  commands and check or cross marks; pending approvals pinned on the right.
- [ ] Approval cards: risk level, what will be touched (target, binding), evidence, and policy
  reason; Approve as the single accent action.
- [ ] Rehearsals: progress bar (7/8), per-case "would have done" and "actually happened" side
  by side, prominent Mark ready.
- [ ] Ledger: dense mono table with hash and verify status pills.
- [ ] Routines: proposed, rehearsed, and live pipeline state with +/- diff stats.
- [ ] Changes, Memory, and charter editor: compact rows, uppercase metadata labels, pills.
- [ ] Move every view to app-shell's new tokens as they land; visual check per push as an
  offscreen snapshot (`ARYA_SCREENSHOTS_HOME=.build/demo-home just screenshots`), never by
  opening the app.

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
- [x] Run now: start a manual run with an input from the Stream tab (`FeatureWrite.startRun`).
- [x] Rehearse: start a rehearsal of the live charter on its casebook from the Rehearsals tab.
- [x] Replay: replay a finished run from the Stream tab and show the divergence report.
- [x] Steward overview: charter version, readiness, last run, and open approvals at a glance.

M4:
- [x] Inbox: questions addressed to person bindings, answered with text, in one list.
- [x] Binding detail in tool calls and actions: which binding served each call (live MCP).
- [x] Routine action results in the stream: exit, signal, or timeout, and stdout and stderr.
- [ ] Sandbox verdict on routine results once the runtime records one (decision 0031, M4).
- [x] Routine approvals show the routine body for the exact version asked about (decision
  0032), with a diff against the previously approved version.
- [x] "Always allow this version" on a routine approval: proposes a charter change adding the
  `routine:<name>@<version>` auto rule (through the charter editor's proposal path).

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

- Run now and Rehearse are writes (`FeatureWrite.startRun`, `.rehearse`); Replay is a read
  (`FeatureWorkspace.replay(run:) -> FeatureReplayResult`, mirroring `ReplaySummary`) and is
  enabled only once the run has ended. Every new seam call defaults to "unavailable" until the
  shell's facade adapter forwards it.

- The inbox lists `approval.requested` questions whose `to` is a `person:` binding (questions
  to `local` stay in the approval queue). An answer is `approval.granted` with the text as
  `note`, the shape the runtime's grant records; declining is a deny. `FeatureRegistry.inbox`
  is ready for app-shell's rail entry. The steward overview leaves out rehearsal case runs.

- A routine approval's version is the routine's live version just before the run's
  `run.started` (how the runtime resolves it, decision 0032); "previously approved" is the last
  other version of that routine whose approval was granted. "Always allow this version" is a
  charter proposal adding `routine:<name>@<version>: auto`, hidden once the charter has it.

- Stream split: `StreamStep.pane` puts tool calls and actions on the right (`work`), all else
  on the left (`conversation`); approvals waiting for a person are pinned at the top of the
  right pane. `run.decision` is `{decision: {id, choice, rationale, alternatives?}}` (the
  recorded shape); the flat shape is still read for older recordings.

- Run thread (supersedes the split pane): one column, top to bottom. A quiet meta line, the
  input the run started from, one line per step, tool calls and actions as mono one-liners
  with a check or cross that expand on click (pretty JSON, wrapping), and the finish step as
  the only place the summary appears. Policy pills show only for ask and deny. An approval is
  an unboxed block: full proposed content (`params.text`), the input it answers, why, binding,
  policy reason, and risk (`ActionRisk` by action kind), with Deny quiet and Approve the one
  accent element. Manual input and Replay sit behind "Run now…" and a "More" menu.

- Every approval entry point renders `InlineApproval`: the run thread inline, and Needs you
  (the queue) as a compact list whose selected item shows the same block, built from the run's
  projected action and input (`NeedsYouDetail`). The old card (`ApprovalItemCard` and the
  registry's no-store fallback) is deleted.

## Questions
- (from app-shell) `FeatureRegistry` now routes Changes, Ledger, Memory, Routines, and
  Rehearsals to your views when a store is wired; metric chart placement is yours. Changes
  shows a primary Accept per proposal, and STYLE.md allows one primary button per pane.
- (from workspace) live on the facade: `routineContent(steward:name:version:)`, `routine(steward:name:version:)`, `routineHistory`, `routines`, `memory(steward:)`, and `caseExpected(casebook:case:) -> Data?` (canonical JSON).
- (from workspace) live: `proposeCharter(steward:charter:baseVersion:title:reason:by:) -> ProposalSummary` (refuses a stale base), `proposals`, `checkProposal`, `acceptProposal`, `rejectProposal(_:reason:)`, `overrideProposal(_:reason:)`, `gateRoutine`, `overrideRoutine`.
- (from cli-e2e) Return-to-approve granted a demo approval on window activation; use Cmd-Return?
- (from app-shell) The app no longer has a preview mode, so `PreviewWorkspace` and
  `PreviewFixtures` are used only by tests; move them into `Tests/AryaAppTests` when convenient.
- (from app-shell) Style pass on the demo home (`just screenshots`), both schemes: the Stream
  Decision step shows no choice in its heading (STYLE.md: choice in the heading, reasoning
  folded); the Ledger filter bar is wider than the pane at 1120 pt (Actor clips) and the time
  column truncates to "jus…now"; Rehearsals truncates "Rehearse ag…"; approval cards and Memory
  show full run ids where a short form fits.
- (from app-shell) Fixed in `ApprovalCard` (decision 0034): Command-Return approves and
  Command-Delete denies; plain Return and Escape do nothing on a card.
- (from workspace) for the app-outcome lane: `outcome(steward:)`, `plan(steward:)` (empty until runtime plan events), `recap(steward:since:)`, `activity(steward:limit:)`, `createSteward(_: StewardDraft)`, `bindings(steward:)`, `people(steward:)` are live.
- (from eval) Shapes: `BacktestComparison`, `ReadinessReport` (reasons with codes), `OutcomeTrend` (points).
- (from adapters) Outcome data is on the wire: `run/result` carries `plan` steps (status pending/in_progress/done/skipped/blocked), action `risk` hints, and one-line `why` on decisions and actions; the triage example emits all three. Runtime is asked to carry them into the ledger (runtime.md Questions).
- (from workspace) for the approval block and Run now: `ApprovalSummary.content/params/source/policyRule/risk`, `approval(_:)`, `RunSummary.title`, `DecisionSummary.why`; writes `startRun(steward:)` / `startRun(steward:input:)`, `rehearse(steward:casebook:)`, `correct(steward:case:expected:note:casebook:by:)`, `markReady(steward:by:)`, `setEffort(_:for:by:)`, `proposeCharter(steward:charter:baseVersion:title:reason:by:)`.
- (from app-outcome) `FeatureRegistry` gained `.overview` (OverviewTab) and `outcomeLine`; `PreviewFixtures.triage` appends `OutcomeFixtures.plan` at its end (two `plan.updated` events). Both are small integration edits.
- (from eval) Show verbatim: `ReadinessReport.summary`, `BacktestCase.summary`, `text`/`diffText`.
- (from workspace) live: `plan(steward:)` items (status pending|in_progress|done|skipped|blocked, reason), `ApprovalSummary.risk/why`, `RunDetail.Action.why/risk`, `DecisionSummary.why` (wire why, else rationale).
- (from eval) Scores: `CaseScore.checks` (label, passed, weight, text) and `scoreText`, verbatim.
- (from workspace) `ApprovalSummary.policyText`: the holding rule's charter `note` (new optional `policy.rules[].note`), else a sentence such as "Reply actions need approval (charter rule)."; `StewardDraft.Rule.note` sets it from New steward.
- (from eval) Verbatim: `CaseScore.sentence` (Improve), `RunCounterfactual.summary` (run thread).
- (from workspace) live: `needsYou() -> [NeedsYouItem{kind approval|failed_run|stale_rehearsal, steward, title, reason, link{kind approval|run|rehearsals, id}, time}]` for the Needs you row; `timeText(_ date) -> TimeText{absolute, relative}` from the workspace clock (use instead of the device clock); `event(seq:) -> EventDetail{entry, payloadText, hash, prev, time, step{run, index, count, title}}` for the inspector; `plan(steward:)` now reads runtime `plan.updated`.
- (from workspace) live: `improve(steward:) -> ImproveView{rehearsal, rehearsalText, ready, markedReady, readinessText, readinessReasons, proposals[{proposal, gate}], cases[{caseID, input, wouldHave, expected, diff, score, passed, leak, corrections}]}` and `knowledge(steward:) -> KnowledgeView{notes[{note, provenance, time}], routines[{routine, versions[{version, summary, gate, approval, time}]}]}`; show the text fields verbatim.
- (from eval) Improve: `LiveReadiness.summary` (one sentence) and `regressionLines`, both verbatim.
- (from workspace) live: correct a run from its thread with `expected(run:choice:) -> Data` (the run's result with a new choice) then `correct(run:expected:note:by:) -> CorrectionSummary` (the run becomes a case; rehearse `casebook` next).
- (from workspace) live: `whatIf(run:proposal:) -> WhatIfSummary{did, wouldHave, differences, fixesCorrection, leak, summary}` under a proposal's charter (or the live one); show `summary` verbatim on the run thread.
- (from workspace) live: `ApprovalSummary.change{field, from, to, text}` for non-reply actions (`label: none → billing`; nil for replies) next to `source`; `policyText` for autonomy holds is now a plain sentence, show it verbatim.

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
- 2026-11-09: Changes tab hosts the metric chart and charter editor (06dcbbb).
- 2026-11-09: run now, replay, and rehearse controls (4ab0e07).
\n- 2026-11-09: inbox, steward overview, and binding detail (acdb4fc).\n- 2026-11-09: routine versions on approvals and always allow (2247b2e).\n- 2026-11-09: Visual check (demo home, dark): Stream split pane with timed conversation rows and work cards with check marks and policy pills; decision rows were empty on real data (nested payload), fixed. Approval card still the old component.\n- 2026-11-09: Visual check (demo home, dark): run thread is one column with no cards, chips, or ids; one accent element (Approve); reply text and the input it answers shown in full; summary once as the final step; input and Replay behind Run now… and More. Remaining on this screen are app-shell's: serif title, effort control, six tabs, run labels.\n
- 2026-11-09: Visual check (offscreen snapshot, demo home, dark): Needs you and the run thread show the same approval block with the reply text, the message it answers, why, binding, policy reason, and risk; no old card, no ULID (4ae22c6). Open on app-shell's side: the header's orange Review button doubles the accent while a run with a pending approval is shown.
- 2026-11-09: Visual check (just snapshot, demo home): Ledger is aligned mono seq/HH:MM:SS/type with run titles, folded adapter events, search with a glyph and hairline, Verify as a quiet action then a status, and an event inspector on `event(seq:)` (e49fbd5). Improve reads `improve(steward:)` when available (rehearsal sentence, readiness reasons, wouldHave/expected/diff per case, gate text) and falls back to the ledger projection; case rows show the choice in sans.
- 2026-11-09: approvals show the workspace's words only. `PolicyText` and the app-side change rule are deleted; `FeatureStore.approvalTexts` carries `ApprovalSummary.policyText` and `change.text` by approval id into `InlineApproval` (run thread and Needs you). Without a change line, structured params read as one sentence (`ActionSummary`, "Refund 24.00 USD on ORDER-1043"), with the raw params under Details. Improve's Correct takes an expected choice plus an optional note; open proposals get a quiet What if… (`whatIf(run:proposal:)` on the latest live run). The ledger inspector reads hash and prev through a cached `FeatureStore.loadEventDetail(seq:)`, mono, middle-truncated, with the full value on hover and Copy. Visual check: `just snapshot` needs-you-autonomy (facade sentence plus `label: none → billing`), run-approval (facade rule sentence), ledger-inspector (hash and prev filled).
- 2026-11-09: two Correct paths, by decision with the CEO. Improve's case rows correct an existing case (`correct(steward:case:…)`, expected choice plus optional note). The run thread's More menu has Correct…, which teaches from a live run with `correct(run:expected:note:by:)` (expected from `expected(run:choice:)`), so the run becomes a new case. `FeatureWrite.correctRun` carries it; a choice alone is enough, the note is optional on both paths.
