# Lane: eval

Owns `Sources/AryaEval` and `Tests/AryaEvalTests`.

Goal: **every change is tested against the past before it goes live, and every run can be
replayed.** Deterministic replay with a divergence report, casebooks, rehearsal, scoring,
corrections, readiness, proposals, gates, and outcome metrics over time. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md#replay), decisions 0015, 0017.

## Backlog

M1:
- [x] Interfaces only, so other lanes can compile against them: `Replayer`, `Rehearser`,
  `Scorer`, `Gate` (conforming to `GateChecking`), with stub implementations.

M2:
- [ ] `arya replay <run>`: rebuild recorded inputs (ambient, adapter messages, tool results,
  executor output, human events), drive the runtime with `ReplayAdapter`, and compare derived
  events field by field; divergence report with both versions. Test with an injected
  nondeterminism bug that replay catches.
- [x] Casebook format and import (JSON Lines), content-hash versions, `casebook.imported`.
- [ ] Rehearsal: one run per case (trigger `case`), tools served from case context, no action
  executed, `leak` detection, `rehearsal.*` events, parallelism bounded and deterministic in
  ordering.
- [x] Scorers: exact match on chosen fields; rubric scorer (weighted checks on result fields).
- [ ] Corrections (`case.corrected`) and readiness (`steward.ready`).
- [ ] Proposals and gates: baseline lookup, samples, tolerance, per-case regression rule,
  override event. Table-driven gate tests.
- [ ] Metric series from `metric.recorded`, action outcomes, and approval rates; per-steward
  series with fixed windows for the app chart.

Later:
- [ ] Judge-adapter scorer (an adapter scores a result against the expected one).

## Decisions

- Until `AryaCore` publishes ids, `Case`, a JSON value, and `GateChecking`, eval uses plain
  string ids, its own `EvalValue`, and `EvalGateChecking` (prefixed so modules importing both
  never see an ambiguous name). Each is replaced when the core type lands.
- Stubs fail safe: replay and rehearsal throw `notImplemented`, the stub scorer fails every case,
  and the stub gate refuses every proposal.
- Replay compares derived events by position (type, then payload in sorted key order), never by
  `seq`, because a replay writes to a scratch ledger. `DivergenceFinder` is pure and landed
  ahead of the runtime-driven replayer.
- `GateRule` (pure, decision 0017): a missing baseline or differing case sets fail the gate; a
  `leak` case counts as failed in every sample and scores 0 in the mean. Scorer paths fan out
  through arrays (`actions.kind`), and an exact or rubric scorer with nothing to check fails.
- Casebooks: cases are sorted by id and a casebook's version is the SHA-256 of canonical JSON
  Lines (sorted keys, no whitespace, `/` unescaped), so reordering or reformatting keeps the
  version. Duplicate ids, `v` other than 1, empty ids, and empty casebooks are rejected. The
  normalized casebook is stored as one blob whose hash equals the version. Writes go through
  `EvalRecorder` (blob put and event append), which the facade adapts to the ledger once it
  lands.

## Questions

## Log

- 2026-11-09: interfaces `Replayer`, `Rehearser`, `Scorer`, `Gate` with stubs (8247b8d)
- 2026-11-09: `DivergenceFinder`, exact and rubric scorers, pure `GateRule` (6a59273)
