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
- [ ] `arya init`, `arya steward create|list|show`, `arya run`, `arya approvals`,
  `arya approve|deny`, `arya ledger tail|verify`. Parsed, rendered, and tested against a fake
  backend and wired to `Workspace` through `WorkspaceBackend`; each turns green as its facade
  call lands (`init` works today).
- [x] `etc/examples/triage/`: a generic issue-triage charter, a fake-adapter script, and a
  casebook of invented past issues.

M2:
- [ ] `arya replay`, `arya casebook import|list`, `arya rehearse`, `arya correct`, `arya ready`,
  `arya propose`, `arya proposals`, `arya metrics`, `arya memory`, `arya routines`,
  `arya binding-proxy`. Parsed, rendered (text and `--json`, `ImprovementModels.swift`), and
  tested. Wired to the facade: `casebook import|list`, `rehearse`, `correct`, `ready`,
  `metrics`, and `run show`; `replay`, `propose`, `proposals`, `memory`, `routines`, and
  `binding-proxy` report the facade call they wait for (workspace lane).
- [ ] `just e2e` (CLI only, fake adapter, temporary home): create, rehearse, correct, ready,
  run, approve, replay with zero divergence, `ledger verify`; non-zero exit on any failure.

M3:
- [ ] Extend `just e2e` with the app's facade calls used by the views.
- [x] `just demo`: seed a demo home from `etc/examples` and open the app on it.
- [ ] README: replace the placeholder with a screenshot and GIF of the demo, update the Status
  table and Usage as commands land.
- [x] `etc/scripts/tidy.sh` upkeep: line length, formatting, secret patterns, zero
  dependencies, `CLAUDE.md` identical to `AGENTS.md`.

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
- (from app-shell) `just demo` can open the app on the seeded home with
  `open -n .build/Arya.app --args --home <path>` after `just app`; app-shell then points
  `just app-preview` at it.
- (from workspace) live: charter proposals (`proposeCharter`, `proposals`, `checkProposal`, `acceptProposal`, `rejectProposal`, `overrideProposal`) and routine gates (`gateRoutine`, `overrideRoutine`) for `arya propose`/`arya routine`.
- (from runtime) `arya binding-proxy --home <home> <rest>`: `BindingProxyArguments(parsing: rest)`, then `BindingProxyHost.proxy(args, sink: LedgerEventSink(home:ambient:))`, then `await BindingProxyHost.serveStandardIO(proxy)`.
- (from ledger) once `LedgerCheck` carries the ledger's report lines (asked in workspace.md), `arya ledger verify` text output can print them as-is; JSON stays unchanged.

## Log
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
