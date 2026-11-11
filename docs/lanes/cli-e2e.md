# Lane: cli-e2e

Owns `Sources/AryaCLI`, `etc/examples`, the `just e2e` and `just demo` recipes, `README.md`, and
`etc/scripts/tidy.sh`.

Goal: **prove the whole loop works, end to end, from a clean checkout.** The `arya` command over
the `Workspace` facade, example stewards and casebooks, the end-to-end scenario, the demo home,
the README, and the tidy scan.

## Backlog

M1:
- [x] Argument parsing without dependencies: subcommands, flags, `--help`, `--home`, `--json`
  output for every listing.
- [x] `arya init`, `arya steward create|list|show`, `arya run`, `arya approvals`,
  `arya approve|deny`, `arya ledger tail|verify`. Parsed, rendered, and tested against a fake
  backend and wired to `Workspace` through `WorkspaceBackend`; each turns green as its facade
  call lands (`init` works today).
- [x] `etc/examples/triage/`: a generic issue-triage charter, a fake-adapter script, and a
  casebook of invented past issues.

M2:
- [x] `arya replay`, `arya casebook import|list`, `arya rehearse`, `arya correct`, `arya ready`,
  `arya propose`, `arya proposals`, `arya metrics`, `arya memory`, `arya routines`,
  `arya binding-proxy`. Parsed, rendered (text and `--json`, `ImprovementModels.swift`), and
  tested, and wired to the facade; `binding-proxy` (now with `--steward` and `--recorded`, as
  the runtime launches it) waits for `Workspace.serveBindingProxy`.
- [x] `just e2e` (CLI only, fake adapter, temporary home): create, rehearse, correct, ready,
  run, approve, replay with zero divergence, `ledger verify`; non-zero exit on any failure.

M3:
- [x] Extend `just e2e` with the app's facade calls used by the views: 33 steps in about 30 s
  (fleet, pause and resume, policy and autonomy holds, deny, gated proposal, run correction,
  retract, docs-only publish).
- [x] `just demo`: seed a demo home from `etc/examples` and open the app on it.
- [x] README: replace the placeholder with a screenshot and GIF of the demo, update the Status
  table and Usage as commands land.
- [x] `etc/scripts/tidy.sh` upkeep: line length, formatting, secret patterns, zero
  dependencies, `CLAUDE.md` identical to `AGENTS.md`.
- [ ] README GIF of the demo (optional; the screenshot is in).

M4:
- [x] `etc/examples/adapters/`: `claude-code` and `codex-cli` exec profiles, equal to
  `AdapterProfiles.examples` (a test keeps them in sync).
- [ ] `arya serve [--every]`: parsed and tested; waits for `Workspace.serve(every:)`.
- [x] `arya serve install|uninstall`: a LaunchAgent (`app.arya.serve`) that runs
  `arya --home <home> serve` at login, logs to `<home>/logs/serve.log`, restarts on failure.
- [ ] Extend `just e2e` with `serve` once it lands: a charter with an interval trigger fires a
  scheduled run within one tick.
- [ ] Example charter with an MCP binding through `binding-proxy`, once the proxy is wired.
- [x] Demo steward that looks weeks old: plan, why, and risk in every scripted run, 26
  history runs (billing, bugs, accounts and sign-in, shipping, refunds, security, spam), a correction, a memory, and a routine proposal; the
  fallback is a hideable status event.
- [x] Spread the demo history over weeks: `ARYA_CLOCK` stamps seeded commands (28 daily metric
  points trending to 0.96, an evolving four-item steward plan).
- [x] Fleet data for M3.5: `etc/examples/{refunds,digest}` and `arya steward pause|resume`; the
  demo seeds three stewards (on track, behind target, paused) on one time-sorted timeline.
- [x] Crew run in the demo (MSG-203 delegates "Draft the refund reply"; a join checks it) and
  `just e2e` steps for the charter editor proposal with readiness and a crew run (37 steps).
- [ ] One `just e2e` step per M3.6 parity item as it lands (docs/ROADMAP.md).
- [x] `arya fleet` on the workspace fleet read (metric vs target, needs you, next wake), e2e step.
  a fleet read.

## Decisions

- `just e2e` (`etc/scripts/e2e.sh`) runs every M3 step through the CLI against a temporary home
  and prints ok, PENDING (exit 69 or an unknown command), or FAIL per step. Steps sit in
  groups (setup, rehearsal, live, metrics, replay); a step is skipped only when a group it needs
  is not ok, so the live run is tested while rehearsal is pending. Exit 0 all ok, 1 failed, 2 pending. Checks read `--json` output with `plutil`, so the
  script needs nothing beyond macOS. The M2 JSON shapes it reads are defined in
  `Sources/AryaCLI/ImprovementModels.swift`.
- `etc/examples/triage` is a support inbox triage steward (CEO request). The scripted steward
  misses only `case-0006`, which the e2e scenario corrects; `ExamplesTests` pins this.
- The CLI talks to an arya home only through `CLIBackend` (`Sources/AryaCLI/Backend.swift`), which
  returns CLI view models (`Models.swift`: `StewardRow`, `ApprovalRow`, `RunReport`, ...; named
  so they do not clash with the facade's `StewardSummary`/`ApprovalSummary`). Those models are
  the `--json` contract: explicit keys, sorted, pretty-printed, slashes unescaped; nil optionals
  are omitted. `WorkspaceBackend` maps the facade into them (`Mapping.swift`); a facade call
  that throws `unavailable` becomes exit 69 naming the call (`Workspace.createSteward`).
- `arya run` derives decisions and action dispositions from the run's ledger entries with a
  lenient reader (`RunDigest`) until the facade offers a run detail (workspace lane backlog). Enrichment calls (pending
  approval counts, last run) are optional: their failure leaves the field empty.
- Exit statuses follow `sysexits`: 0 ok, 1 failure (failed run, broken ledger), 64 usage,
  65 invalid input, 66 not found, 69 not available yet. `just e2e` treats 69 as "pending".
- Home resolution: `--home`, then a non-empty `ARYA_HOME`, then the per-user default; relative
  paths resolve against the working directory, `~/` against the user's home. Read once in
  `main.swift`.
- Global options (`--home`, `--json`, `-h/--help`, `--version`) are accepted anywhere before `--`.
- CLI tests live in `Tests/AryaCLITests` and use `@testable import AryaCLI` (executable target).
- 2026-11-10 (CEO): the busy demo keeps its full history (1244 runs with eval's rehearsals);
  no trim. It seeds in 236 s at load 40 (0.19 s per run, from ~0.9 s before the facade cache
  and runtime's incremental run start), and the date-plus-inputs stamp with the shared seeded
  home (a 5 s copy) means each worktree pays it at most once a day.

## Questions
- (from workspace) Live: core calls, `charter(_:)`, `run(_:) -> RunDetail?`, `importCasebook(steward:data:name:)`, `casebooks(steward:)`, `rehearse(steward:casebook:)`, `rehearsals(steward:)`, `expected(steward:case:choice:)` (for `--choice`), `correct(steward:case:expected:note:casebook:by:)`, `markReady(steward:by:)`, `metrics(steward:windowSeconds:)`, `memory`, `routines`, `routine`, `routineHistory`; `replay(run:) -> ReplaySummary` (on eval's `RunReplayer`; `just e2e` 15/15).
- (from app-shell, answered) Look at the seeded demo home with `just snapshot` (offscreen
  renders to `.build/snapshots`, decision 0038); never open the app window.
- (from workspace) live: charter proposals (`proposeCharter`, `proposals`, `checkProposal`, `acceptProposal`, `rejectProposal`, `overrideProposal`) and routine gates (`gateRoutine`, `overrideRoutine`) for `arya propose`/`arya routine`.
- (from runtime) `arya binding-proxy --home <home> <rest>`: `BindingProxyArguments(parsing: rest)`, then `BindingProxyHost.proxy(args, sink: LedgerEventSink(home:ambient:))`, then `await BindingProxyHost.serveStandardIO(proxy)`.
- (from ledger) once `LedgerCheck` carries the ledger's report lines (asked in workspace.md), `arya ledger verify` text output can print them as-is; JSON stays unchanged.
- (from adapters) Optional M4 nicety: `AdapterProfiles.examples` holds ready exec profiles (`claude-code`, `codex-cli`); an `arya adapters init` (or `arya init`) could write them into the home's `adapters.json` with `JSONEncoder`, keeping existing profiles.
- (from app-shell) `docs/assets/app.png` is the README screenshot (light Stream tab of the
  demo home, 1600 px, about 350 KB); `just readme-screenshot` refreshes it. Embed it in README.
- (from runtime) `arya serve`: take `SchedulerLock.acquire(home:)` (exit if nil), then `RuntimeService(engine:recovery:notifier:).run(every: .seconds(30))` with the facade's engine and shared `FileRunLeases`; executor `BindingActionExecutor`.
- (from governance, 2026-11-10, per the CEO) The governance CLI is built and on main; please
  do not duplicate it. Commands (`Sources/AryaCLI/GovernanceCommands.swift`, backend in
  `WorkspaceBackend.swift`): `arya steward policy <id>`, `arya undo <run> [<action>]
  [--reason]`, `arya retention [--steward <id>] [--days <n>|--clear]`, `arya retention apply`,
  `arya encryption [--enable] [--reseal]`, `arya export <steward> --signed --out <dir>
  [--reveal]`, `arya export verify <dir>` (exit 1 when it does not check), `arya import <dir>`.
  `approve --as` and `run abort` were already yours and are unchanged. e2e group `governance`
  adds steps 51-58 (policy, undo options, undo, retention, export, verify, a changed byte fails
  verify, import into a fresh home); all ok. The three older "(from governance)" CLI asks
  below are done. Separately: step 37 (MSG-203 crew) fails on main with "crew children 2,
  no join run"; not from this change.
- (from adapters) `etc/examples/triage/fake-script.json` results now include `plan`, decision and action `why`, and action `risk` (per the CEO); `just e2e` still passes 15 of 15.
- (from eval) Backtest demo data: `Tests/AryaEvalTests/Fixtures/backtest` (README); copy to examples?
- (from app-outcome) please seed the demo home with a steward plan: have the fake triage script return `plan` in `run/result` (protocol `PlanStep`s: `id`, `text`, `status` pending|in_progress|done|skipped|blocked, `rationale`) on both live runs, changing one step between them, so the runtime records `plan.updated` and the Overview shows a plan and why it changed. A few days of `metric.recorded` history would also fill the sparkline.
- (from adapters) Per the CEO, the triage fake script now answers `New message MSG-202: Where is my package?` (shipping) and `New message MSG-203: Damaged order, please refund` (label, route, a high-risk `refund` on binding `billing`, and a reply). To show them: add a `billing` binding to `etc/examples/triage/charter.json` (`actions: ["refund"]`, policy `refund: ask`) and seed both runs in `etc/scripts/demo.sh`; MSG-201 and the casebook are unchanged, so `just e2e` is unaffected.
- (from workspace) `Workspace.open(home:environment:ambient:)` is live: seed with `Ambient.fixed(start: <weeks ago>, stepMillis: 60_000)` for a `--clock`, then views read it as weeks old (the current demo home is all stamped at seed time).
- (from eval) FYI per CEO: demo proposes `charter-v2.json`; `arya propose` now gates (help said so).
- (from workspace) live: `correct(run:expected:note:by:)` and `expected(run:choice:)` for an `arya correct --run <id> --choice <c>`.
- (from workspace) live: `fleet()` (the fleet read you asked for) for `arya steward list`.
- (from governance) `approve(_:note:as:)` for `arya approve <id> --as person:alex`, and `policySummary(steward:)` for `arya steward policy <id>`. e2e step: add `policy.approvers` for `refund` (people `person:alex`) to the triage example, show `arya approve` as local is refused (exit non-zero, `approval.refused` on the ledger), then approve `--as person:alex`.
- (from governance) `abortRun(_:reason:as:)` for `arya run abort <run> [--reason <text>]`; e2e step: start a hanging fake run in the background, abort it, and check `run.finished` status `stopped` and no `action.executed`.
- (from connect) Please add an e2e step for connections once `arya` can list a steward's
  bindings; the app page is covered by `ConnectionsCatalogTests` and the `connections` snapshot.
- (from governance) `undoAction`/`undoOptions` for `arya undo <run> <action> [--reason]`; e2e step: add `policy.undo` (`label` → `unlabel`, binding lists `unlabel`) to the triage example, undo a label, approve the compensation, and check `action.undo.requested` then `action.executed` for `undo:<id>`.
- (from app-views) proposed: seed one crew run in the demo home (a run whose result delegates one child that finishes and one that is refused for an unlisted adapter, decision 0043), so the run thread's crew lines show on real data; the app already renders `run.delegated`.
- (from connect) FYI: gave `person:sam` in `etc/examples/triage` a name, role, and
  a `policy.approvers` rule for `reply` (local or Sam) so the demo People page has content;
  please add an e2e step that a person's approvals survive a charter proposal.
- (from workspace) live: `serveStatus()` for `arya serve`; e2e and demo can use `createFromTemplate`, `portfolio()`, `remember(...)` (shared or per steward), and `message(steward:text:intent:by:)`; the templates are in `etc/examples/templates`.
- (from eval) Added triage/history-export.jsonl, demo history import + review, e2e steps 15-18.
- (from governance) The triage example charter now has `policy.undo` (label → unlabel) and the inbox binding lists `unlabel`, so the demo and e2e can undo a label (`undoOptions`/`undoAction`).
- (from connect) Added `arya message <steward> <text> [--as person] [--intent ask|correct|handoff]`
  and `arya report show|send <steward>` in `Sources/AryaCLI/PeopleCommands.swift` (with
  `WorkspaceBackend` methods); `etc/scripts/demo.sh` seeds messages and reports with them.
- (from runtime) Integration edits (decision 0051): `arya serve` now runs `Workspace.startServing` (was `missing`), with `--demo-pace`; `demo.sh --live` seeds, sets `ARYA_FAKE_PACE_MS=1500` on the demo's fake profiles, and execs `arya serve --demo-pace`. A busier fake script (tool calls with multi-line string output) makes the paced runs read better.
- (from workspace) facade reads are now incremental (`FacadeCache`: books, approvals detail, rehearsals, casebooks, per-steward events); your `runBook()` cache fix is subsumed — `runBook()` reads the cached state. Tests: second read after N events folds N; 50k-event home warm reads under 20 ms.
- (from eval) Busy demo: refunds/digest casebooks 43/32, examples/proposals.json, e2e 26 cases.


- (from governance, DONE 2026-11-10 by governance: see the entry above) CLI for the governance facade: `arya steward policy <id>` (`policySummary`), `arya run abort <run> [--reason]` (`abortRun`), `arya undo <run> <action>` (`undoOptions`/`undoAction`), `arya retention [--steward <id>] [--days <n>|--clear]`, `arya retention apply` (`applyRetention`), `arya home encryption [--enable]` (`encryption`/`enableEncryption`), `arya audit export <steward> --out <dir> [--reveal]` and `arya audit verify <dir>` (`exportAudit`, `Workspace.verifyAudit(at:)`, non-zero exit when issues). e2e: export the triage steward and verify it, then flip one byte in events.jsonl and expect verify to fail.
- (from governance, DONE 2026-11-10 by governance: see the entry above) CLI for the governance facade: `arya steward policy <id>` (`policySummary`), `arya run abort <run> [--reason]` (`abortRun`), `arya undo <run> <action>` (`undoOptions`/`undoAction`), `arya retention [--steward <id>] [--days <n>|--clear]`, `arya home encryption [--enable]` (`encryption`/`enableEncryption`), `arya audit export <steward> --out <dir> [--reveal]` and `arya audit verify <dir>` (`exportAudit`, `Workspace.verifyAudit(at:)`, non-zero exit when issues). e2e: export the triage steward and verify it, then flip one byte in events.jsonl and expect verify to fail.
- (from runtime) Demo data (decision 0055): the fake scripts can return `findings` (problem or opportunity, evidence, suggestion, `needsPerson`) on scheduled runs so the demo home shows proactive findings; a binding listing the `outcome` read tool gets follow-up checks (decision 0054) under `serve --demo-pace` a minute after each real execution.

- (from governance, DONE 2026-11-10 by governance: see the entry above) CLI for the governance facade: `arya steward policy <id>` (`policySummary`), `arya run abort <run> [--reason]` (`abortRun`), `arya undo <run> <action>` (`undoOptions`/`undoAction`), `arya retention [--steward <id>] [--days <n>|--clear]`, `arya retention apply` (`applyRetention`), `arya home encryption [--enable|--reseal]` (`encryption`/`enableEncryption`/`resealHistory`), `arya audit export <steward> --out <dir> [--reveal]` and `arya audit verify <dir>` (`exportAudit`, `Workspace.verifyAudit(at:)`, non-zero exit when issues). e2e: export the triage steward and verify it, then flip one byte in events.jsonl and expect verify to fail.
- (from governance) CLI for the governance facade, still open: `arya steward policy <id>` (`policySummary`), `arya run abort <run> [--reason]` (`abortRun`), `arya undo <run> <action>` (`undoOptions`/`undoAction`), `arya retention [--steward <id>] [--days <n>|--clear]`, `arya retention apply` (`applyRetention`), `arya home encryption [--enable|--reseal]` (`encryption`/`enableEncryption`/`resealHistory`), `arya audit export <steward> --out <dir> [--reveal]` and `arya audit verify <dir>` (`exportAudit`, `Workspace.verifyAudit(at:)`, non-zero exit when issues). e2e: export the triage steward and verify it, then flip one byte in events.jsonl and expect verify to fail.
- (from workspace) `verifyLedger()` now carries `lines` (the ledger's report: headline, where, meaning, next step) for `arya verify`; `serveStatus().scheduler` explains who serves (scheduler or leased runs).
- (from eval) For the Swift seeder: per generated steward `buildCasebook(steward:limit:60)`,
  `rehearse`, and a titled `proposeCharter(title:reason:)` (titles must match diffs: see
  `demoProposalTitlesDescribeTheirDiffs`); port demo.sh's refunds history (`binding:
  "billing"`), triage/refunds reviews, and `etc/examples/proposals.json`.
- (from runtime) Integration edits (decision 0059): `arya steward onboard <steward>` (`CommandID.stewardOnboard`, `OnboardReport`, `TextRender.onboard`, backend default in the `CLIBackend` extension). Demo: a triage binding listing `directory` and `process` over the example `inbox-history.json` data would make the demo home show onboarding notes; add an e2e step if you wire it.
- (from runtime) `OnboardSummary.records` (decision 0063): past records summarized from `history`; worth a word in `arya steward onboard` text and an e2e step with a history binding.
- (from runtime) e2e for grants (decision 0064), once workspace stores them: a message from a person without a use grant proposes an action that is rejected `access:use` with a problem finding (`arya findings`); add the grant and the same message executes; a person without an approve grant is refused on `arya approve` (`approval.refused`, rule `grant:approve`) and one with it approves.
- (from runtime) Grants are now storable (decision 0065): facade `setTeam`, `grantAccess`, `revokeAccess`, `undoAccess`, `access()`. For the 0064 e2e an `arya access` command (list, grant, revoke, team, undo) would drive it; then message as a person without a grant (refused, `access.refused`, finding), grant, message again (executes).

## Log
- 2026-11-11: ROADMAP M3.6 #1 flipped to done (app-outcome: wizard guardrail metrics,
  205d5c5e); 15 done, 3 partial, 0 missing.
- 2026-11-11: load fix (CEO): publish takes its queue ticket before `just fmt` (only cheap git
  checks come first; test-publish asserts nothing is formatted while waiting), and the demo
  seeder runs in a CI slot. `just build`, `just test`, the snapshot's `swift test`, and the
  e2e and demo builds already went through `etc/scripts/slot.sh`.
- 2026-11-11: seeded runs read as real work: each adapter update moves the seeding clock 3-40 s
  (by event kind and a per-steward tempo), actions take 1-6 s, runs take 30 s to 6 min, and
  start times are off the hour. The seed's "today" is local midnight (it was 00:00 UTC, so an
  evening reseed moved the history a day). New test: every active steward has live runs on 5
  of the last 7 days. readiness counts a crew once (e2e, 80 steps; eval's open item 3 was
  already fixed by 85be5e4a). Visual check (run, run-diff-window, overview, portfolio-live):
  steps 6-68 s apart, runs 1m38s and 5m54s; overview RUNS 7 DAYS has a bar every day; the
  portfolio's RUNS 7D column still spikes on rehearsal days until it reads `runHistory`.
- 2026-11-10: graded-run e2e (79 steps): e2e seeds a three-example demo home (about 40 s) and
  asserts `steward trajectories` shows good runs and a credit line, since real homes run
  actions dry. ROADMAP 4 flipped to done: 14 done, 4 partial, 0 missing.
- 2026-11-10: Visual check (`just snapshot overview-live portfolio-live`, current seed):
  portfolio-live shows 11 stewards by department, 7 need you, 5 behind, 1 running, with
  sparklines, costs, and fleet activity; overview-live leads with 0.94 / 0.90 on track, the
  live LEAD-LIVE run at step 9, three findings, Impact, and PLAN "Changed Nov 7" with the new
  pricing item (review 15 nit fixed). Wrong: RUNS 7D bars and the 7-day chart spike on one day,
  because the seeded rehearsal runs (42 for lead follow-up at 05:00 Nov 8) count as runs; asked
  workspace to count live runs only.
- 2026-11-10: `arya findings`, `arya finding resolve`, `arya template list|use`, with six e2e
  steps (77): the triage script's "Sweep the inbox for patterns" raises a problem and an
  opportunity; a person acts on the problem. ROADMAP 12 and 16 now name their e2e. Next: a
  graded run for `steward trajectories` once eval seeds follow-up checks (#4).
- 2026-11-10: `arya steward onboarding|gate|trajectories|metrics` (onboardingState, goLiveGate,
  trajectories, metricStatuses; `steward onboard` stays runtime's action), each with an e2e
  step (71 steps). The live steward re-plans three days before the seed's today, so its PLAN
  reads recent (CEO review 15). ROADMAP M3.6 now has a status table with commit refs: 13 done,
  5 partial, 0 missing; e2e gaps named (routines, proactive findings, templates).
- 2026-11-10: seed retimed: 1244 runs in 236 s at load 40 (0.19 s per run); no hotspot left
  in a sample (no full-ledger reads, fsync under 1%). Full history kept (CEO).
- 2026-11-10: publish queue (decision 0058): `just publish` waits for its turn first come
  first served (`etc/scripts/publish-queue.sh`, test-publish scenario `queue`); run facts and
  steward live landed in 66f2b140.
- 2026-11-10: `arya run facts <run>` and `arya steward live <steward>` (the facade's one source
  of run numbers and live state); e2e checks a run's facts (3 drafted, none waiting) and the
  long run in `steward live` before and after the abort. The triage MSG-203 example now
  delegates only in run (`host/delegate`, runtime 6b26d22b): its `result.delegations` copy made
  a second child. Seed fixes (triage bad week, one pending reply per order), shared seeded
  homes by stamp, and the uncached-path asks landed in 56bc2896. e2e 55 steps.
- 2026-11-10: busy demo home (decision 0051): `arya-demo` seeds 11 stewards in 8 departments
  (3 examples, 8 from templates), 685 runs over 4-8 weeks with weekday rhythm, a bad week three
  weeks ago and a recovery, failed runs, 11 approvals waiting across 7 stewards (the rest
  decided), messages, proposals, memory, today's runs and cost; about 13 min under load 38
  (facade calls scan the ledger; workspace is making them incremental). `just snapshot` copies
  the home and keeps a live lead run in progress. Connect's people threads, reports, and
  `demo.sh --live` now go through the seeder. e2e: message ask and correct, report show and send
  (52 steps). Visual check: pending app-shell's snapshot settle fix (point 5).
- 2026-11-10: Paused for the night after the approvers and abort batch. Next: an e2e step per
  new M3.6 item (undo through compensation, retention plan, connection probe without Keychain).
- 2026-11-10: `arya fleet` (workspace fleet read); `arya approve --as`, approvers on
  `arya approvals`, `arya run abort`; e2e 42 steps (fleet read, refused approver recorded, abort a
  long run from another process; MSG-204 sleeps 30 s in the triage script); demo seeds a last
  look 2 h before the newest activity in `app/visits.json` (asked app-outcome to read it).
- 2026-11-10: crew in the demo (MSG-203's `delegations` plus a `joins` response in the fake
  script, keyed by delegation id); `arya run show` lists crew and join; `arya readiness`; e2e 37
  steps (editor proposal and readiness, crew run); ROADMAP M3.6 parity map. Readiness on crew
  runs asked of eval. Published as b8d0b5a.
- 2026-11-09: `arya run correct` (a run becomes a case and a memory), `arya retract`, and
  `heldBy`/`heldBecause` on `arya approvals`; `just e2e` grows to 33 steps (about 30 s), with
  `test-publish.sh docs-only` as its publish step; ROADMAP M3.5 refreshed.
- 2026-11-09: decided the zero-time id question myself (ledger lane paused): fixed in
  `Ambient` (ids before the first clock reading carry the start time, with a core test); the
  CLI's extra clock read is gone, and `clockedRunIDsSortByTime` still guards it.
- 2026-11-09: README shows the dark Overview and run-approval snapshots (f7574f3). Fleet data:
  refund follow-up (0.86 against 0.90, one reply waiting) and weekly digest (paused) stewards,
  `steward pause|resume`, one time-sorted demo timeline (1755 events, 25 s). Clocked runs read
  the clock once so their ids sort by time (question in ledger.md).
- 2026-11-09: union-merged lane files (ad671b9), timed publish with a docs-only fast path
  (e7fe1f8, decision 0041), weeks of demo history (c66f2ae). Publish preflight: refuses a dirty
  tree, clears a stale `index.lock`, commits `just fmt` changes, aborts a conflicting rebase;
  `just test-scripts` covers it (7 scenarios against throwaway repos).
- 2026-11-09: no-window rule: `just demo` only seeds (look with `just snapshot`). `ARYA_CLOCK`
  over workspace's `Workspace.open(home:environment:ambient:)` backdates seeding: setup 30 days ago, one run a day,
  28 metric windows from 0.62 to 0.96, five `plan.updated` as the steward plan evolves, two
  routine versions, guardrail notes on the charter's policy rules; about 12 s.
- 2026-11-09: default run is a real inbox check (e7699be). Demo: 26 history runs plus 2 live,
  `why` on every decision and action, the high-risk refund reply held; seeding skips the build
  when binaries are current (11 s). Metric windows wait for a facade clock.
- 2026-11-09: M3.5 section in ROADMAP (1a1d360). Demo steward enriched: history runs with `plan`,
  `why`, and `risk` (adapters lane format), `history.txt` replayed by `just demo`, fallback is a status event.
- 2026-11-09: M4 start: adapter profile examples, `arya serve install|uninstall` login item,
  `serve` and `binding-proxy` waiting on facade calls (asked in workspace.md). Previous push
  65544bf.
- 2026-11-09: `memory`, `routines`, `proposals`, and `propose` wired to the facade; only
  `binding-proxy` waits. `just e2e` passes all 15 steps. README shows a light-mode app
  screenshot of the demo home (`docs/assets/stream-light.png`, captured with `screencapture -l`
  on a background launch); Status and Usage refreshed. CI slot lock landed (d0d3bfa).
- 2026-11-09: CI slot lock (decision 0033): `etc/scripts/slot.sh` holds one of two `lockf`
  slots in the git common dir around every swift build and test (`just build`, `just test`,
  `just screenshots`, `bundle-app.sh`); builds pass `-j 6`. Recipes now quote their
  arguments (`just publish`, `just e2e`, `just demo`). `arya replay` wired to the facade (0ecf639).
- 2026-11-09: casebook, rehearse, correct, ready, metrics, and `run show` wired to the facade;
  `arya run` and `steward show` use `run(_:)` and `charter(_:)`. `just e2e`: 14 of 15 ok.
  ```
   1  init a home                          ok
   2  create the triage steward            ok
   3  import the casebook                  ok
   4  rehearse: 7 of 8 pass                ok
   5  correct case-0006                    ok
   6  rehearse again: 8 of 8 pass          ok
   7  mark the steward ready               ok
   8  run live on a new message            ok
   9  the reply waits for approval         ok
  10  approve the reply                    ok
  11  the approved reply executed          ok
  12  the run recorded its metric          ok
  13  metric series updated                ok
  14  replay the run: zero divergence      PENDING  Workspace.replay (workspace lane)
  15  verify the ledger                    ok
  ```
- 2026-11-09: `just demo` seeds `.build/demo-home` from the example and opens the app (08541c0)
- 2026-11-09: e2e in dependency groups; steps 1-2 and 8-11 and 15 pass on the real facade;
  `arya run` reads nested `run.decision` payloads (5087332)
- 2026-11-09: `just publish <TestFilter>` (d3f06eb) (etc/scripts/publish.sh) implements decision 0029
- 2026-11-09: faster `just ci` (one `--build-tests` build, parallel lint), decision 0029,
  AGENTS.md publish rule; unavailable messages point at the workspace lane (ee69024)
- 2026-11-09: example script back on the canonical `responses`/`default` format
- 2026-11-09: tidy checks `CLAUDE.md` = `AGENTS.md`, shell syntax, no workflow files (8491625)
- 2026-11-09: README status, usage, and e2e description (260de38)
- 2026-11-09: example script moved to the adapters lane's `runs`/`steps` format, checked with
  `FakeScript.load` (1600165)
- 2026-11-09: M2 commands parsed and rendered, waiting on facade calls (ac81054)
- 2026-11-09: `WorkspaceBackend` over the facade replaces `PendingBackend`; `arya init` works
  (c9871fc)
- 2026-11-09: examples validated through `Charter.load` and `Case.load` (ebd2ba3)
- 2026-11-09: `just e2e` runner with ok, PENDING, FAIL per step (2338549)
- 2026-11-09: support inbox triage example, casebook, fake script (7646ccc)
- 2026-11-09: argument parser, command table, help, text and `--json` output, `CLIBackend`
  with `PendingBackend` (6b4ff5c)
- (from eval) Seeder: casebook build+rehearse per steward, refunds review, titled proposals
- (from eval) Seeder: nightly `checkOutcomes` + `OutcomeReads.add` on charters (follow-ups)
