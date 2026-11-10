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

The M3 checklist passes, but the app was far from the target experience. Owners are in
parentheses; status as of 2026-11-09, evening. "Landed" means on main. The reviewer passed the
redesigned Overview and run-approval screens; the other screens still await review. `just e2e`
(37 steps, about a minute) drives the facade flows behind these screens headlessly.

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

arya has about half of what an outcome-owning agent platform offers. Functional parity comes
before polishing any one screen. An item is done only when it works end to end in the app:
reachable, on real data, with a `just snapshot` state, a Visual check line in its lane, tests, and
a `just e2e` step. Status is done, partial, or missing; owning lanes are in parentheses (new
lanes: connect, governance). `e2e:` names what `just e2e` covers today.

1. Outcome, success definition, guardrails, ownership (app-outcome UI). Partial: the New steward
   wizard and the charter editor exist; the scope of what a steward owns and multiple metrics
   are missing. e2e: create, editor proposal through its gate and readiness.
2. Self-onboarding: the steward ingests connected systems and history and builds context about
   people, processes, and decisions (runtime; app-outcome UI). Missing.
3. Train on history: run against past tickets, deals, and decisions, see what it would have
   done, correct, decide when ready (eval; app-views UI). Partial: casebook rehearsal, Correct,
   and Mark ready exist; importing real history from a connection as cases, and a review queue
   to go through cases one by one, are missing. e2e: rehearse, correct a case, correct a run
   into a case, mark ready.
4. Learn from results after acting: watch the outcome and credit it to past actions (runtime;
   app-outcome UI). Missing.
5. Changes simulated against past cases before going live. Done: the proposal gate and live
   readiness. e2e: a regressing proposal fails its gate; an editor proposal passes and is ready.
6. Works where people work (chat, email, team chat); anyone can ask, correct, or hand off, and
   corrections improve it for everyone (connect). Partial: the local inbox and email and chat
   relay exist; conversation threads in the app, hand-off tasks, and attribution to many people
   are missing.
7. Self-written routines in a versioned repository; repeatable work becomes reusable code
   (app-views UI). Partial: routine proposals and versions exist; a browsable repository with
   diffs and per-version stats is missing.
8. Custom policies; sensitive actions approved first. Done: charter policy, autonomy, and risk.
   e2e: a policy hold and an autonomy hold, each explained; approve and deny.
9. Precise metrics, or evaluations it builds from its own work and expert judgment (eval).
   Partial: metrics and the rubric judge exist; evaluations built automatically from
   corrections and expert labels are missing. e2e: the run's metric and series.
10. Fleets: fan out sub-agents across tasks and scale with the work (app-views UI). Partial:
    crew delegation exists, and the demo seeds one crew run; a fleet view of active children and
    parallel fan-out are missing. e2e: a crew run whose child only proposes, then a join.
11. Organizational memory: preferences and best practices across people and runs, updated as it
    learns (workspace). Partial: memory with retract exists; per-person preferences and scope
    (one steward or shared) are missing. e2e: a correction becomes a memory; retract.
12. Persistent and proactive: keeps working for weeks and surfaces problems and opportunities on
    its own (runtime; app-views UI). Partial: the scheduler exists; a feed of proactive findings
    and opportunities is missing.
13. Governance: fine-grained access by organization, team, user, and tool; every action
    attributable and auditable (governance). Partial: the ledger audit is done; roles and
    approver permissions are missing. e2e: verify the ledger.
14. Sandboxed execution, encryption at rest, configurable retention (governance). Partial: the
    sandbox is done; encryption and retention are missing.
15. Many stewards per organization, by department, with a portfolio view (workspace facade;
    app-shell UI). Partial: the sidebar lists stewards with health, and the demo seeds three;
    a portfolio screen with every outcome against its target is missing. e2e: three stewards,
    pause and resume.
16. Templates: start from an example steward such as lead conversion, vendor spend, adoption,
    commitments, or support triage (workspace facade; app-shell UI). Missing.
17. Reports to people: a periodic digest of progress (connect). Missing.
18. Abort and rollback paths (governance). Missing.

## M4 — Real harnesses

- `arya-exec-adapter` profiles for common command-line agents; MCP tool bindings passed through
  the binding proxy to live systems.
- Bindings for people: a local inbox the app shows, plus an email or chat binding through MCP.
- Scheduler as a login item (`arya serve`), notifications for approvals.
- Routine sandboxing: a macOS `sandbox-exec` profile for `routine` actions (decision 0031).

## Later

Judge-adapter scorers, `host/delegate` for in-run crews, ledger compaction
with signed checkpoints, export and import of stewards, multi-workspace.
