# Lane: app-outcome

Owns `Sources/AryaApp/Features/Outcome`, `Sources/AryaApp/Features/Onboarding`, and their
tests in `Tests/AryaAppTests` (`Outcome*Tests.swift`, `Onboarding*Tests.swift`).

Goal: **every steward screen leads with its outcome.** Opening a steward shows what it owns,
how it is doing against the target, its current plan, and what it did recently and why.
Creating a steward feels like defining an outcome with guardrails, not writing JSON.

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

- [x] Overview tab, the default and first steward tab: recap paragraph for a returning
  person, the current plan as a quiet checklist with why it changed, Recent activity (mono
  action and target, muted why, expands to policy, risk, and run), details on demand
  (success, readiness, autonomy, next wake).
- [x] Outcome line component above the tabs: KPI in large mono against its target,
  sparkline, status pill, and the pane's one primary action (Review N approvals, else a quiet
  Run now). `FeatureRegistry.outcomeLine(context)`; app-shell owns its final placement.
- [x] New steward sheet on the same canvas, one question group per step (Outcome → Metric
  and target → Guardrails and sign-off → Connections → Schedule), one primary Continue,
  advanced fields behind disclosure; inline validation; creates through the facade's
  `createSteward(StewardDraft)`; lands on the Overview with "Rehearse on past work" next.
- [x] First-launch empty state: one sentence, an orange New steward, a quiet Open demo.
- [ ] Switch reads to the facade's `outcome`, `plan`, `recap`, `activity` and eval's `OutcomeTrends`,
  `ReadinessReports` once `plan`
  returns real items; delete the event projections each replaces.
- [ ] Onboarding: Systems and People (bindings with connection status and a test button) and
  Context (what the steward knows about people, history, and past decisions, from memory).
- [ ] Schedule: triggers, next wake, recent trigger outcomes, uptime over weeks.

## Decisions

- 2026-11-09: loosening proposals (guardrails removed, sign-off loosened, adapter swapped)
  confirm like ownership changes rather than only expanding the diff: both remove a safety
  property, so neither may be the one-click default.

- 2026-11-09: proposal review compares the gate's baseline and candidate rehearsals case by
  case (passed → failed is worse, failed → passed is better); nothing goes live by default,
  so a regressed proposal offers no peer Accept. The workspace `liveReadiness` read is wired
  (`FeatureWorkspace.liveReadiness`) for eval's comparison read when it lands.

- Visual checks are offscreen snapshots only (CEO, user directive; decision 0038): `just
  snapshot` PNGs in `.build/snapshots`. Never open the app or show a window.

- Visual target (CEO): one dark canvas, no boxes or cards, structure from whitespace and
  type, monospace for machine text, small uppercase labels, one orange accent for the
  primary action and things needing attention, at most one primary action per screen.
- The Overview projects from ledger events in the `FeatureStore` (live refresh, works on the
  preview fixtures) until the facade's `plan` is real; types are prefixed `Outcome*` and the
  facade's `OutcomeSummary` stays the facade's name.
- The sparkline spaces samples evenly by index (daily means, or each reading while there
  is under two days). A flat tail means equal readings: the demo's 20 readings fall on one
  day and the last dozen are 0.80; cli-e2e is asked for backdated history.
- Times use `AryaTime.label` (short in row gutters, long in prose); the recap reads "Since
  you looked 21m ago: …". No local formatters.
- New steward steps never ask for config syntax. Connections come before guardrails so
  sign-off can list the actions the chosen connections offer. Connections are known bindings
  from other stewards' charters, switched on (a custom command sits behind Advanced). People
  are a name and a channel picker per row with a quiet "+ Add person". Sign-off is a checklist
  of action kinds with each one's risk as the runtime resolves it (a charter `policy.risk`
  entry, else the risk recorded on `action.proposed`, else runtime's default by kind: label
  and route low, reply medium, close and refund high, other kinds medium; mirrored until the
  facade risk read lands)
  and a default from autonomy: asking first checks everything, acting on its own checks only
  high risk. "Never allowed" is a second checklist behind Advanced. Every kind becomes a rule.
- The charter editor is the New steward steps on the live charter (`CharterEdit.swift`):
  answers are read from the charter, edits merge back into it keeping every field the steps
  do not manage (limits, scorer, gate, crew, risk levels, rule notes, other triggers), and it
  ends in "Propose change" (`proposeCharter`, gated, shown in Improve), never a direct save.
  Actions with no rule follow the charter default; generated rules that only restate the
  default are left out; reordering alone is not a change. Opened by Steward > Edit Charter…
  (⇧⌘E) and `FeatureRegistry.editCharter`, which the settings button should call.
- The New steward sheet uses no system accent: `NewStewardChoice` (drawn like
  `EffortSelector`) and `NewStewardCheck` replace segmented pickers and the checkbox.
- Status: on track when the latest daily value meets the target in its direction; at risk
  when it falls short by at most 5% of the target; otherwise off track; no target or no
  readings say so.
- Plans are read from the runtime's `plan.updated` `{items, reason?}` (actor: the steward,
  run: the run that changed it; `steps` is also read for older fixtures). Steps take the protocol's
  `PlanStep` (`text`, `rationale`, `pending | in_progress | done | skipped | blocked`) or the
  fixtures' (`title`, `note`, `todo | doing | done | dropped | blocked`). An action's reason
  is its `why`, else its `rationale`, else the disposition reason. Step changes are diffed against the previous plan by title.
- Risk shows only when `action.proposed` carries `risk` (or `action.risk`); nothing is
  inferred from the policy.
- Recap uses the newest seq the person saw on that steward's Overview, kept in user
  defaults (`arya.outcome.lastSeen.<steward>`); the facade keeps no per-person state. The
  recap paragraph shows only for a returning person when something happened or waits.
- Selecting another steward opens its Overview (replaces "keep the tab" from app-shell).
- app-outcome owns `OutcomeLine` (CEO); app-shell keeps only the header slot that places it.
- New steward: lists are one item per line or comma separated (no JSON). Automatic and
  sign-off action kinds become `auto` and `ask` rules and are offered by the first system;
  "never" kinds become `deny` rules. The app computes the id (`st_` and the facade's slug) so
  it can land on the new steward. Opened from Steward > New Steward… (⇧⌘N; ⌘N stays New
  Window) and the first-launch screen. Open demo opens the sheet filled with the generic
  support-inbox example, since the app cannot seed a demo home itself.
- A steward that is not ready shows "Not ready: … Rehearse on past work" at the top of its
  Overview, which opens rehearsals.
- `AryaFont.metric` (mono 28/32, medium) added to AryaDesign for the KPI; proposed to
  app-shell for STYLE.md.

## Questions

- Should Open demo seed a real demo home (casebook, rehearsals, runs) from the app? Today it
  fills the New steward sheet with the example; seeding needs a facade call.
- (from app-views) proposed, relayed from app-shell's paused-steward split: when `context.steward?.status == .paused`, the OutcomeLine status reads PAUSED, muted, in place of on/off track.
- (from runtime) `Workspace.context(steward:)` gives people (with message, correction, decision counts and notes) and connections (with use counts and notes) for a People and connections surface (decision 0047); re-plans record `plan.updated` with reason "Re-planned after …" (0046).

## Log

- 2026-11-09: lane created; Overview tab (default, first) and the shared outcome line.
  Visual check: demo home shows KPI 1.00 / 0.95 on track, Review 1 approval in orange, Plan
  empty (no `plan.updated` yet), Recent one line each with why; no boxes. Rehearsal case
  runs no longer leak into Recent or the overview's last run. Top bar, serif title, effort
  in header, and seven tabs remain app-shell's.
- 2026-11-09: New steward sheet (five steps, structured create), first-launch screen, plan
  steps in the protocol's shape, `why` as the action reason.
- 2026-11-09: CEO fixes: clock times instead of "just now", recap only after 15 min away
  ("Since yesterday: …"), unboxed status label, sparkline from readings within a day,
  waiting rows open the approval; plans read the runtime's `plan.updated {items, reason}`.
- 2026-11-09: Plan hidden until the steward has one; recap drops the last-run sentence (it
  is the first Recent row); risk and why fall back to each run's recorded `run/result`.
- 2026-11-09: one time rule with the sidebar (relative under 24 h, then clock time).
  Visual check (offscreen `just screenshots`, demo home): outcome line 0.80 / 0.95 with
  sparkline and OFF TRACK label, plan 4/4 with why it changed, Recent with whys, one orange
  Review (the header copy is gone on main).
- 2026-11-09: moved to `AryaTime.label`; "Changed 21m ago"; New steward steps 2-5 render
  in `just snapshot` (`new-steward-2…5`) with ink controls in place of system blue, and Effort
  is labeled once. Visual check (offscreen `just snapshot`): overview, new-steward 1-5 dark and
  light pass the 5 requirements.
- 2026-11-09: New steward steps 3-5 rebuilt with real controls (connection toggles, people
  rows with channel picker, sign-off checklist with risk), a drawn ink checkbox, and content
  top-aligned with the footer right under it. Visual check (offscreen `just snapshot`):
  new-steward 1-5 dark and light pass the 5 requirements; no config syntax outside Advanced.
- 2026-11-09: sign-off risk now follows the runtime (charter `policy.risk`, recorded
  resolution, else `medium`), so `reply` reads medium in the wizard and in approvals.
- 2026-11-09: autonomy shows one muted line saying it only sets where the sign-off list
  starts; never rows dim fully; snapshot frame centered (form about 18% down).
- 2026-11-09: wizard risk mirrors runtime's default-by-kind table; the autonomy line
  follows the checklist (default per autonomy, or "Checked actions wait for you" once
  edited). Visual check (offscreen `just snapshot`): new-steward-4 shows label/route low,
  reply medium, close high, and copy matching the checks.
- 2026-11-09: plan marks: done green ✓, in progress ◐, blocked (waiting on a person)
  orange ◷ like pending approvals, dropped muted ✕, failed red ✕.
  Visual check (offscreen `just snapshot`, reseeded demo): plan 2/4 with ◐, ✓✓, and an orange
  ◷ on the step waiting for approval; 0.96 ON TRACK with a weeks-long sparkline.
- 2026-11-09: charter editor on the New steward steps, ending in a gated proposal. Visual
  check (offscreen `just snapshot`): charter-editor (step 1, prefilled) and charter-editor-5
  (why + "Change outcome. It goes live once its gate passes." + Propose change), dark and
  light, pass the 5 requirements.
- 2026-11-09: Improve's proposal review (now owned here): change-and-why title, "Rehearsal:
  7 of 8 cases unchanged, 1 got worse." with only "worse" in the destructive tone, changed
  cases as expandable before → after rows from the gate's baseline and candidate
  rehearsals, the charter as a unified diff with +/- counts (open up to 6 changed lines).
  Regressed: quiet Reject, Accept anyway… behind More with a confirm naming the cases;
  passing: one orange Accept plus quiet Reject. PAUSED status on the OutcomeLine; CONTEXT
  disclosure on the Overview (people, connections, memory notes, recent decisions); Overview
  rows at a 24 pt pitch with 16 pt gaps; a stale last look reads "Since Oct 11: …"; editor
  step 5 says "This changes the outcome. It goes live after rehearsal passes."; charter
  rule decisions use the ink choice, not a system segmented picker. Visual check (offscreen
  `just snapshot`, reseeded demo home): overview, improve, improve-proposals (regressed and
  passing), dark and light, pass the 5 requirements.
- 2026-11-09: approver safety on proposals. A change to the outcome sentence or the metric
  and target shows "This changes what the steward owns: old → new." above the diff, and
  Accept is quiet and confirms, naming the change, even when cases got better. A change
  that removes guardrails, loosens sign-off (ask → auto, deny → allowed, a looser
  default), or swaps the adapter says what it removes, opens its diff, and also confirms.
  Only tightening or neutral passing proposals get the orange Accept. Classified in the
  app from proposed vs live charter (`ProposalImpact`); asked workspace for a facade
  classification. Visual check (offscreen `just snapshot`): improve-proposals with an
  ownership change (quiet Accept…), a tightening (orange Accept), a regression with an
  outcome change, and the demo's loosening (guardrail and adapter sentence), dark and
  light, pass the 5 requirements.
- 2026-11-09: the sign-off line on the demo proposal: the detector was right (every decision
  is unchanged; the proposal drops the rule notes), so a muted line now says "Sign-off
  decisions stay the same; drops the explanation on 5 rules."; tests cover ask → auto per
  kind and through the default. Sentences no longer double their period after a quote. The
  New steward sheet and charter editor are two columns (920 pt): a step rail with checks
  (done steps reachable, later ones faint until the earlier ones are complete; the editor
  lists what changed) and the step on the right with its footer at the bottom. Visual check
  (offscreen `just snapshot`, reseeded demo home): new-steward-2..5, charter-editor,
  charter-editor-5, improve-proposal-full (the demo's whole diff, 2000 pt tall), dark and
  light, pass the 5 requirements.
- 2026-11-09: Paused for the night by the user's order. Stopped after the two-column sheets
  and the sign-off line. Next: the dense Overview outcome line and the composer at the
  bottom, the inspector's steward context (plan, schedule, connections, people), palette
  commands for my actions, then parity: onboarding ("Getting to know your team"), scope plus
  multiple metrics, Impact, Findings. The user judged the app under 60% of the visual target;
  visual feel is tomorrow's top priority.
