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

## M4 — Real harnesses

- `arya-exec-adapter` profiles for common command-line agents; MCP tool bindings passed through
  the binding proxy to live systems.
- Bindings for people: a local inbox the app shows, plus an email or chat binding through MCP.
- Scheduler as a login item (`arya serve`), notifications for approvals.
- Routine sandboxing: a macOS `sandbox-exec` profile for `routine` actions (decision 0031).

## Later

Judge-adapter scorers, `host/delegate` for in-run crews, ledger compaction
with signed checkpoints, export and import of stewards, multi-workspace.
