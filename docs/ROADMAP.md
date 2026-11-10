# Roadmap

Milestones are ordered. Lanes work in parallel inside a milestone; each lane's ordered backlog is
in its file under [lanes](lanes/README.md). Design is in [ARCHITECTURE.md](ARCHITECTURE.md) and
[PROTOCOL.md](PROTOCOL.md).

## M0 — Skeleton (done when `just ci` is green on main)

Package with every module and test target, docs, style guide, Justfile, tidy, hooks, staged CI,
app bundle script.

## M1 — Engine room (done when a manual run with the fake adapter is fully on the ledger)

- Core: `Ambient` (clock, ids, seeded RNG) with live, fixed, and recorded variants; typed ids;
  canonical JSON; `Charter` and `Case` with validation; `GateChecking` protocol.
- Ledger: event envelope, hash chain over written bytes, segmented store with per-append lock
  and `fsync`, torn-line repair, `verify`, blob store, typed payloads, projections (stewards,
  runs, approvals).
- Adapters: protocol types, stdio JSON-RPC transport, process supervision with timeouts,
  `FakeAdapter` in-process and the `arya-fake-adapter` binary, conformance suite.
- Runtime: create a steward, start a manual run, stream adapter events into the ledger, apply
  the policy, approval queue, execute approved actions through a recording executor, restart
  recovery of interrupted runs.
- Facade: `Workspace.open(home:)` exposing stewards, runs, approvals, and a ledger event stream.
- CLI: `arya init`, `arya steward create|list|show`, `arya run`, `arya approvals`,
  `arya approve|deny`, `arya ledger tail|verify`.

## M2 — Improvement loop (done when a proposal is gated on a casebook from the CLI)

- Eval: `arya replay <run>` with a divergence report; casebook format and import; rehearsal with
  exact-match and rubric scorers; corrections; readiness; proposals and gates; metric series.
- Memory: notes with provenance and retrieval; corrections become notes; retraction.
- Routines: content-addressed library, proposals from runs, gated promotion, routine execution as
  an action kind.
- Runtime: binding proxy serving recorded tool results, interval and calendar triggers with a
  single scheduler, crews with bounded fan-out and join runs, budgets.
- CLI: `arya replay`, `arya casebook import|list`, `arya rehearse`, `arya correct`,
  `arya ready`, `arya propose`, `arya proposals`, `arya metrics`, `arya memory`,
  `arya routines`.

## M3 — The app and the end-to-end scenario

- App shell: window, rail, header, tab bar, effort selector, approval queue placement, design
  system components.
- Feature views: run stream, approval queue and cards, ledger table with verify, memory, routines
  with version diff, rehearsals with per-case review, correction and Mark ready, metric chart,
  charter editor.
- `just e2e`: with the fake adapter, define a steward from `etc/examples`, rehearse it on a
  recorded casebook, correct one case, mark it ready, run it live, approve an action, see the
  ledger and metric update, replay the run with zero divergence, and verify the ledger.
- `just demo`: seeds a demo home and opens the app on it; README screenshot and GIF.

## M3.5 — App parity (done when the app reads as a working steward, not a log viewer)

**#1 priority (user feedback, 2026-11-09 night).** The user compared the overview, run, and
command palette snapshots against the visual target. Verdict: less than 60% of the look, and
not even remotely close to the feel. Green CI and reviewer scores are not the bar; the user
is. Fix these five before any other app work:
1. A run is a sparse log, not a work pane. Raw JSON dumped as INPUT; the right side is run metadata. Target: a split work pane, with the conversation on the left and live tools, diffs, logs and command output on the right, streaming as it happens.
2. Dead space everywhere. The bottom 40% of every screen is empty, the inspector is mostly blank, and the top padding is large. Density must come from real content, not wider margins.
3. Controls read as plain labels ("Edit charter...", "Pause", Low/Medium/High). Actions need clear, compact, keyboard-hinted affordances.
4. The feel is missing: no sense of an agent working live, no streaming, no motion or progress, no inline diffs, no keyboard-driven flow beyond the palette. It feels like a static report.
5. The content is thin: 3 stewards and a short plan. The demo home must look like a busy, real workspace. Landed (cli-e2e, 2026-11-10): 11 stewards across 8 departments, 685 runs over 4-8 weeks with weekday rhythm and one bad week, 11 approvals waiting, messages, proposals, and a live run in progress during `just snapshot`.

The M3 checklist passes, but the app was far from the target experience. Owners are in
parentheses; status as of 2026-11-09, evening. "Landed" means on main. The reviewer passed the
redesigned Overview and run-approval screens; the other screens still await review. `just e2e`
(42 steps, about 30 s once built) drives the facade flows behind these screens headlessly.

- Restyle (app-shell, app-views). Landed in a clean single-canvas style instead of the dense
  dark layout first listed (decision 0036): hidden title bar, four tabs, one accent.
- Outcome-first steward screen: metric against target with a sparkline, plan, recap, and
  activity with reasons (app-outcome, workspace, eval). Landed: the Overview tab reads outcome,
  recap, activity, and runtime plans from the facade.
- New steward flow: outcome, metric, target, guardrails, autonomy, bindings (app-outcome,
  workspace). Landed, with structured create in the facade and real connection, people, and
  sign-off controls.
- Planning that adapts (runtime, adapters). Partly landed: runs return a plan, and stewards keep
  it across runs (`plan.updated`, decision 0035), and plan steps waiting on a person show the
  approval clock; re-planning within a run is open.
- Risk and autonomy levels with explained approvals (runtime, app-views). Landed (decision
  0037): actions carry risk (with defaults per action kind), stewards an autonomy level, and
  approvals say in a sentence which rule or autonomy level held them (`arya approvals` shows it
  too).
- Backtest comparison and readiness visible (eval, app-views). Partly landed: backtest,
  readiness, and trend read models and a live readiness gate exist; Improve shows rehearsals,
  proposals with their regressions, and What if (a run under another charter); a side-by-side
  backtest comparison view is open.
- Onboarding to systems and people, and a context view of people, history, and decisions
  (app-outcome, runtime, memory work through workspace). Partly landed: the New steward flow
  connects systems and people; the Knowledge tab lists memory with live retract, and correcting
  a run from its thread records it as a case and a memory. A context view of people and history
  is open.
- People channels: local inbox, email, and chat (runtime, app-outcome). Partly landed: the
  runtime's local inbox, a Needs you list, and email and chat relayed through MCP bindings for
  people; app screens for those channels are open.
- Sandboxed routines and adapters (runtime). Landed: routines, binding servers, and exec agents
  run under an OS sandbox profile in the run workdir, and replay uses a sandboxed engine.
- Fleet view of sub-agents (app-views, workspace). Partly landed: the sidebar shows each
  steward's health, the demo seeds three stewards (on track, behind, paused), and stewards can be
  paused and resumed (app and `arya steward pause|resume`). Crews run (children propose, a join
  acts), the demo seeds one, and `arya run show` lists a run's crew and join; a fleet read in the
  facade, the fleet view, and showing a steward's crew in the app are open.
- Schedule and long-running work view (app-outcome). Partly landed: the runtime exposes each
  steward's next wake and recent trigger outcomes; the view is open.

## M3.6 — Outcome platform parity (functional parity before polish)

Functional parity comes before polishing any one screen. Each item has a status (done,
partial, missing) judged on what works end to end in the app on real data, the commits that
built it, its owning lanes, and what `just e2e` covers. Status as of 2026-11-10: 14 done,
4 partial, 0 missing.

| #  | Item                                   | Status  |
| -- | -------------------------------------- | ------- |
| 1  | Outcome, guardrails, ownership         | partial |
| 2  | Self-onboarding                        | partial |
| 3  | Train on history                       | done    |
| 4  | Learn from results after acting        | done    |
| 5  | Changes simulated before going live    | done    |
| 6  | Works where people work                | done    |
| 7  | Self-written, versioned routines       | done    |
| 8  | Custom policies, approvals first       | done    |
| 9  | Metrics and self-built evaluations     | done    |
| 10 | Fleets of sub-agents                   | done    |
| 11 | Organizational memory                  | partial |
| 12 | Persistent and proactive               | done    |
| 13 | Fine-grained access and audit          | partial |
| 14 | Sandbox, encryption, retention         | done    |
| 15 | Many stewards, portfolio               | done    |
| 16 | Templates                              | done    |
| 17 | Reports to people                      | done    |
| 18 | Abort and rollback                     | done    |

1. Outcome, success definition, guardrails, ownership (workspace; app-outcome). Partial: the
   New steward wizard, the charter editor, and guardrail metrics with per-metric status
   (b611e046); the scope of what a steward owns is missing. e2e: create, editor proposal
   through its gate and readiness, `steward metrics` (primary vs target).
2. Self-onboarding (runtime, workspace; app-outcome). Partial: onboarding from directory and
   process bindings (b8ac5b7b), the onboarding state (8ffeb88a), and the "getting to know your
   team" overview (7406e974); reading connected systems end to end is still thin ("read 0 of 3
   systems" in e2e). e2e: `steward onboarding` (24 history cases, 7 steps).
3. Train on history (eval; app-views). Done: history import as cases and the review queue
   (e3187fc7, 91452312), import from a binding and a real folder connector (a05aad51,
   e02b9fd3), and the go-live gate. e2e: import, rehearse with history, review, agree,
   `steward gate`.
4. Learn from results after acting (runtime, eval; app-outcome). Done: outcome checks scored
   per action kind (bbe9256d), trajectory grading with credit (8703fef0), Impact in the app
   (b4548d6e), and seeded follow-up checks (0596e756). e2e: `steward trajectories` on a seeded
   demo home shows good runs and credit per action kind.
5. Changes simulated against past cases before going live (eval). Done: the proposal gate and
   live readiness. e2e: a regressing proposal fails its gate; an editor proposal passes.
6. Works where people work; anyone can ask, correct, or hand off (connect). Done: person
   threads, hand-offs as tasks (fc534a04), relay delivery (c385cd5d), and who corrected what
   (c8bd367a). e2e: a person asks and corrects.
7. Self-written routines in a versioned repository (connect, app-views). Done: routine
   proposals and versions, version diffs (4cdd93de), and the Routines library with pass rate,
   runs per day, and Use in steward gated on the target's casebook (50c7fd6d, decision 0060).
   Snapshot: `routines-library`; e2e: none yet.
8. Custom policies; sensitive actions approved first (governance). Done. e2e: a policy hold and
   an autonomy hold, each explained; approve, deny; `steward policy`.
9. Metrics, or evaluations built from its work and expert judgment (eval). Done: metrics, the
   rubric judge, learned checks from corrections and agreements (fff15ee0, 73b922e6), and a
   casebook built from accepted runs (cbde7e1e). e2e: metric series, checks, casebook build.
10. Fleets: fan out sub-agents (runtime; connect). Done: crew delegation, in-run
    `host/delegate` children (6b26d22b), and the crew fan-out view following the run live
    (50c7fd6d). Snapshot: `crew-fanout-live`; e2e: a crew run whose child only proposes.
11. Organizational memory (workspace). Partial: memory with retract and memory scopes, one
    steward or shared (618b1ce6); per-person preferences are read-only. e2e: a correction
    becomes a memory; retract.
12. Persistent and proactive (runtime; app-outcome). Done: the scheduler, proactive findings
    (afc02209), and overview findings (b4548d6e). e2e: a sweep raises a problem and an
    opportunity; `arya findings`, and a person acts on one (`arya finding resolve`).
13. Governance: fine-grained access, attributable and auditable (governance). Partial: the
    ledger audit, approver rules enforced and recorded (9af3f91c), and a people directory with
    roles (cc50514f); access by organization, team, and tool is missing. e2e: a refused
    approver is recorded, the allowed one approves; verify the ledger.
14. Sandboxed execution, encryption at rest, retention (governance). Done: the OS sandbox,
    encryption (d87306ce) and re-sealing older history (24284e8a), retention applied by
    archiving (ed96bb79), all in the app (6c940da4). e2e: retention, signed export and import.
15. Many stewards by department, with a portfolio (workspace; app-shell). Done: the portfolio
    (5ebcf471), fleet by department (4f7e44ed), and the busy demo of eleven stewards
    (e93b1289). e2e: three stewards, pause and resume, `arya fleet`.
16. Templates (workspace; app-shell). Done: templates in the facade (618b1ce6) and the
    templates step in New steward (4f7e44ed). e2e: `arya template list`, and `arya template
    use` creates a steward from one.
17. Reports to people (connect). Done: periodic reports (fc534a04), report runs to relay people
    (c385cd5d), and the reports pane with delivery (c8bd367a). e2e: report show and send.
18. Abort and rollback (governance). Done: abort from any process (9af3f91c), undo through a
    policy-gated compensation (09749ec7), both in the app (6c940da4). e2e: abort a long run;
    undo a label.

## M4 — Real harnesses

- `arya-exec-adapter` profiles for common command-line agents; MCP tool bindings passed through
  the binding proxy to live systems.
- Bindings for people: a local inbox the app shows, plus an email or chat binding through MCP.
- Scheduler as a login item (`arya serve`), notifications for approvals.
- Routine sandboxing: a macOS `sandbox-exec` profile for `routine` actions (decision 0031).

## Later

Judge-adapter scorers, `host/delegate` for in-run crews, ledger compaction
with signed checkpoints, export and import of stewards, multi-workspace.
