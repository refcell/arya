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
- [ ] New steward sheet on the same canvas, one question group per step (Outcome → Metric
  and target → Guardrails and sign-off → Connections → Schedule), one primary Continue,
  advanced fields behind disclosure; inline validation; creates through the facade's
  `createSteward(StewardDraft)`; lands on the Overview with "Rehearse on past work" next.
- [ ] First-launch empty state: one sentence, an orange New steward, a quiet Open demo.
- [ ] Switch reads to the facade's `outcome`, `plan`, `recap`, `activity` and eval's `OutcomeTrends`,
  `ReadinessReports` once `plan`
  returns real items; delete the event projections each replaces.
- [ ] Onboarding: Systems and People (bindings with connection status and a test button) and
  Context (what the steward knows about people, history, and past decisions, from memory).
- [ ] Schedule: triggers, next wake, recent trigger outcomes, uptime over weeks.

## Decisions

- Visual target (CEO): one dark canvas, no boxes or cards, structure from whitespace and
  type, monospace for machine text, small uppercase labels, one orange accent for the
  primary action and things needing attention, at most one primary action per screen.
- The Overview projects from ledger events in the `FeatureStore` (live refresh, works on the
  preview fixtures) until the facade's `plan` is real; types are prefixed `Outcome*` and the
  facade's `OutcomeSummary` stays the facade's name.
- Status: on track when the latest daily value meets the target in its direction; at risk
  when it falls short by at most 5% of the target; otherwise off track; no target or no
  readings say so.
- Plans are read from `plan.updated` `{v: 1, steps: [{id, title, status: todo | doing | done
  | dropped | blocked, note?}], reason?}` (actor: the steward, run optional), proposed to the
  workspace and runtime lanes. Step changes are diffed against the previous plan by title.
- Risk shows only when `action.proposed` carries `risk` (or `action.risk`); nothing is
  inferred from the policy.
- Recap uses the newest seq the person saw on that steward's Overview, kept in user
  defaults (`arya.outcome.lastSeen.<steward>`); the facade keeps no per-person state. The
  recap paragraph shows only for a returning person when something happened or waits.
- Selecting another steward opens its Overview (replaces "keep the tab" from app-shell).
- `AryaFont.metric` (mono 28/32, medium) added to AryaDesign for the KPI; proposed to
  app-shell for STYLE.md.

## Questions

## Log

- 2026-11-09: lane created; Overview tab (default, first) and the shared outcome line.
  Visual check: demo home shows KPI 1.00 / 0.95 on track, Review 1 approval in orange, Plan
  empty (no `plan.updated` yet), Recent one line each with why; no boxes. Rehearsal case
  runs no longer leak into Recent or the overview's last run. Top bar, serif title, effort
  in header, and seven tabs remain app-shell's.
