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
- [ ] Extend `just e2e` with the app's facade calls used by the views.
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
- (from adapters) `etc/examples/triage/fake-script.json` results now include `plan`, decision and action `why`, and action `risk` (per the CEO); `just e2e` still passes 15 of 15.
- (from eval) Backtest demo data: `Tests/AryaEvalTests/Fixtures/backtest` (README); copy to examples?
- (from app-outcome) please seed the demo home with a steward plan: have the fake triage script return `plan` in `run/result` (protocol `PlanStep`s: `id`, `text`, `status` pending|in_progress|done|skipped|blocked, `rationale`) on both live runs, changing one step between them, so the runtime records `plan.updated` and the Overview shows a plan and why it changed. A few days of `metric.recorded` history would also fill the sparkline.
- (from adapters) Per the CEO, the triage fake script now answers `New message MSG-202: Where is my package?` (shipping) and `New message MSG-203: Damaged order, please refund` (label, route, a high-risk `refund` on binding `billing`, and a reply). To show them: add a `billing` binding to `etc/examples/triage/charter.json` (`actions: ["refund"]`, policy `refund: ask`) and seed both runs in `etc/scripts/demo.sh`; MSG-201 and the casebook are unchanged, so `just e2e` is unaffected.
- (from workspace) `Workspace.open(home:environment:ambient:)` is live: seed with `Ambient.fixed(start: <weeks ago>, stepMillis: 60_000)` for a `--clock`, then views read it as weeks old (the current demo home is all stamped at seed time).

## Log
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
