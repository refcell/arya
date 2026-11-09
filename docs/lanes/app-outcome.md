# Lane: app-outcome

Owns `Sources/AryaApp/Features/Outcome`, `Sources/AryaApp/Features/Onboarding`, and their
tests in `Tests/AryaAppTests` (`Outcome*Tests.swift`, `Onboarding*Tests.swift`).

Goal: **every steward screen leads with its outcome.** Opening a steward shows what it owns,
how it is doing against the target, its current plan, and what it did recently and why.
Creating a steward feels like defining an outcome with guardrails, not writing JSON.

## Backlog

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
  entry, else the risk recorded on `action.proposed`, else `medium`; one source with approvals)
  and a default from autonomy: asking first checks everything, acting on its own checks only
  high risk. "Never allowed" is a second checklist behind Advanced. Every kind becomes a rule.
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
