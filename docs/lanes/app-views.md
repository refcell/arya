# Lane: app-views

Owns `Sources/AryaApp/Features`.

Goal: **every part of a steward's life visible and correctable from the app.** The feature views
that live inside the shell: run stream, approvals, ledger, memory, routines, rehearsals,
metrics, and the charter editor. All visuals come from `AryaDesign`; no raw colors or font sizes
([STYLE.md](../STYLE.md)).

## Backlog

**#1 item, before everything below (user feedback, 2026-11-09 night).** The user compared the overview, run, and
command palette snapshots against the visual target. Verdict: less than 60% of the look, and
not even remotely close to the feel. Green CI and reviewer scores are not the bar; the user
is. Fix these five first; this lane owns its share:
1. A run is a sparse log, not a work pane. Raw JSON dumped as INPUT; the right side is run metadata. Target: a split work pane, with the conversation on the left and live tools, diffs, logs and command output on the right, streaming as it happens.
2. Dead space everywhere. The bottom 40% of every screen is empty, the inspector is mostly blank, and the top padding is large. Density must come from real content, not wider margins.
3. Controls read as plain labels ("Edit charter...", "Pause", Low/Medium/High). Actions need clear, compact, keyboard-hinted affordances.
4. The feel is missing: no sense of an agent working live, no streaming, no motion or progress, no inline diffs, no keyboard-driven flow beyond the palette. It feels like a static report.
5. The content is thin: 3 stewards and a short plan. The demo home must look like a busy, real workspace.

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
- (from eval) Fixed ChangeList: ledger uses `proposal` (not `id`) and nests the gate in `verdict`.
- (from governance) live: `ApprovalSummary.approvers` (who may grant it; nil = anyone) and `approverNote`; show "Needs person:alex" on the card and the facade's refusal text verbatim when Approve is refused (the approval stays pending, `approval.refused` lands in the ledger). `policySummary(steward:) -> PolicySummary{autonomy, fallback, bindings[{id, kind, tools, network, via, actions[{kind, decision, reason, risk, approvers, approverNote}]}], approvers[{action, binding, people, note}]}` for one Policy section (tool allowlist, what runs alone, what waits and for whom). Please add a snapshot state with a guarded approval.
- (from governance) live: `abortRun(_ id, reason:, as:) -> RunSummary` for an Abort button on a running run (run thread header and the fleet/schedule views). The run ends `stopped` within a poll (or fails `aborted` when no process holds it); nothing it proposed executes. Please add a snapshot state of a run aborted mid-way (the thread shows `run.abort.requested` with who and why).
- (from governance) live: `undoOptions(run:) -> [UndoOption{run, action, kind, binding, target, with, note, undoneBy}]` and `undoAction(run:action:reason:as:) -> UndoSummary{option, decision, reason, approval, executed}` for an Undo control on executed actions in the run thread (hide it when `undoneBy` is set; an `ask` undo appears in the approval queue as `undo:<id>`). Snapshot state: a run with one undone label.
- (from governance) live: `retention() -> RetentionSummary{defaultDays, stewards[{steward, days}], segments, through, events, bytes, blocker}` and `setRetention(steward:days:as:)` (nil steward = home default, nil days clears) for a Retention row in steward settings and home settings; show `blocker` verbatim when set. Snapshot state: a steward with 90-day retention.
- (from workspace) live: `message(steward:text:intent:by:) -> MessageReceipt{event, note, run}` for the composer (ask and handoff run and return the run; correct returns the note), `conversation(steward:)` for the thread, `runNow(steward:note:)` for ⌘↩; `portfolio()` and `templates()`/`createFromTemplate(_:id:name:adapter:owner:)`; `KnowledgeView.shared` (notes every steward recalls) and `remember(_:steward:about:by:)`.
- (from eval) Added ReviewQueuePanel on Improve, FeatureStore.reviewQueues, FeatureWrite.reviewCase.
- (from governance) live: `encryption() -> EncryptionSummary{enabled, key, algorithm, keyAvailable, since, clearEvents, sealedBlobs, clearBlobs}` and `enableEncryption(as:)` for an Encryption row in home settings: "Off" with an Encrypt button (confirm: "the key lives in your Keychain; without it this home cannot be read"), else "On, key hk_…" and, when `clearEvents > 0`, "N earlier events stay as written". A home whose key is missing fails `Workspace.open` with `HomeEncryptionError.locked(key:)`; show its description instead of a blank window. Snapshot state: an encrypted demo home (open it with `keys: MemoryHomeKeyStore()`).
- (from governance) Landed myself (the asks above were open a day and the user judges the app): `RunGovernanceControls` (Abort on live runs ⌘., Undo with a list) sits before `RunControls` in `StreamTab`'s accessory; views and `GovernanceCache` live in governance-owned `Features/Governance/`. Restyle or move freely; keep the controls reachable from the run header. Snapshot states `governance-run`, `governance-run-controls`.

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
- 2026-11-09: paused stewards (split with app-shell, which owns the sidebar, Pause/Resume, and the header). Run now… and Rehearse stay enabled, because a manual run is a deliberate person action. A muted "Paused: scheduled runs are off." sits under each (`ActionNote`, from `context.steward?.status == .paused`), with the workspace's refusal inline when a write fails. Needs you is unchanged. Visual check: `just snapshot` run and improve unchanged for active stewards; no paused page exists yet.
- 2026-11-09: Needs you rows name the steward from its charter (`StewardNames`, muted sans) and use `AryaTime.label(style: .short)` in the gutter ("14m", "Nov 8"). The ledger never pages. "Showing 1280 of 1755" was the steward scope, so the header now reads "1280 events for this steward" ("N matching" once the person filters; "N events" unscoped). A muted line after the last row names what the scope leaves out, and Verify reports the whole chain's count ("✓ chain verified · 1755 events"). There is no ledger-wide view to link to, so that line offers no "Show all". Visual check: `just snapshot` needs-you (names, short times) and ledger (header count).
- 2026-11-09: the ledger's scope, by CEO decision (no new screen). A steward's Ledger tab has Show: This steward (default) or All events in its Filter menu. All events shows every steward and the system, with the steward column back as the muted steward name (`LedgerTable.stewardNames`) and the Steward filter section. The end-of-list line reads "475 more events belong to other stewards or the system · Show all", and Show all switches the scope. Visual check: `just snapshot` ledger unchanged at the default scope; the menu and end line are below the offscreen frame.
- 2026-11-09: crew in the run thread. `run.delegated` (decision 0043) becomes one step, `.delegated(DelegationStep)`, shown as an indented line ("↳ ✓ drafted the refund reply · child run · 2.1 s") with the status as its mark. It expands inline to the child run's own steps, projected from the same ledger, and the child's budget ("budget: adapter fake · effort low · 4 turns · 60 s · $0.20"). A refused delegation reads "refused: adapter browser is not in the crew". `PreviewFixtures.crew` feeds the tests and a new `run-crew` snapshot page, which opens crew lines through the `crewOpenByDefault` environment value. Visual check: `just snapshot` run-crew (child expanded, one mark per line, refused line muted).
- 2026-11-09: the run thread reads like a dense, keyboard-first developer workspace. The header adds the run's facts in mono (`RunMetrics`: adapter, effort, duration, tokens, cost from `run.started` and `run.finished`). Tool lines show their main argument and a short result after an arrow ("✓ inbox.get MSG-202 1 ms", "✓ label inbox:MSG-202 → shipping"). Machine output folds after four lines behind "· N lines hidden". A one-line composer sits under the thread: an Ask / Correct / Hand off menu, ↩ sends `FeatureWrite.message` (inbox, decision 0039; the facade call is requested in workspace's Questions, so it reports unavailable until then), and ⌘↩ starts a run with the text. Visual check: `just snapshot` run (facts line, arrows, composer with keycap hints) and run-crew.
- 2026-11-10: run header facts on their own mono line with plural counts ("1 decision · 2 actions"); duration and cost read "—" when unknown, never "0.0 s" or "$0". Tool calls start expanded, so output reads inline, folded after four lines. `RunFacts` was renamed `RunMetrics` because the shell's inspector owns `RunFacts`. Needs you inspector content: `FeatureRegistry.approvalInspector(context, approval:)` (`ApprovalInspector`, `ApprovalFacts`: steward name, run link, the workspace's policy sentence, risk, earlier decisions on the same target), and `ApprovalQueueView(selection:)` to share the selection; the shell mounts it. Visual check: `just snapshot` run (facts line, inline folded tool output, composer).
- 2026-11-10: a run's input reads in plain words (`RunInput`). A crew report (`join`) shows one sentence per child ("Drafted the refund reply for MSG-203. 1 action proposed for approval.") with "Open child run · <title>", and the header reads "checks the delegated work from <parent run title>". Other structured input gets a one-line summary. Raw JSON sits behind a collapsed "Show raw", never inline and never with ids. Needs you keyboard: j/k and ↑/↓ move, A approves (high risk asks first), D denies, keycap hints under the queue; Esc no longer denies. The selection binds to `navigation.approval` for the inspector. Palette: Approve and Deny for the selected approval (keys A, D) in `FeatureRegistry.commands`. Visual check: `just snapshot` run (crew report sentence, Show raw collapsed) and needs-you (keycaps, approval inspector).
- 2026-11-10: Paused for the night by user order. Stopped after the run input and Needs you keyboard commit. Next: shorten the join header (the parent title wraps to two lines); Ledger j/k and ↩ with keycaps; then the visual-target work the CEO sets as tomorrow's top priority; then #3 Review history queue.
