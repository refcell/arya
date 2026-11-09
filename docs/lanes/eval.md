# Lane: eval

Owns `Sources/AryaEval` and `Tests/AryaEvalTests`.

Goal: **every change is tested against the past before it goes live, and every run can be
replayed.** Deterministic replay with a divergence report, casebooks, rehearsal, scoring,
corrections, readiness, proposals, gates, and outcome metrics over time. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md#replay), decisions 0015, 0017.

## Backlog

M1:
- [ ] Interfaces only, so other lanes can compile against them: `Replayer`, `Rehearser`,
  `Scorer`, `Gate` (conforming to `GateChecking`), with stub implementations.

M2:
- [ ] `arya replay <run>`: rebuild recorded inputs (ambient, adapter messages, tool results,
  executor output, human events), drive the runtime with `ReplayAdapter`, and compare derived
  events field by field; divergence report with both versions. Test with an injected
  nondeterminism bug that replay catches.
- [ ] Casebook format and import (JSON Lines), content-hash versions, `casebook.imported`.
- [ ] Rehearsal: one run per case (trigger `case`), tools served from case context, no action
  executed, `leak` detection, `rehearsal.*` events, parallelism bounded and deterministic in
  ordering.
- [ ] Scorers: exact match on chosen fields; rubric scorer (weighted checks on result fields).
- [ ] Corrections (`case.corrected`) and readiness (`steward.ready`).
- [ ] Proposals and gates: baseline lookup, samples, tolerance, per-case regression rule,
  override event. Table-driven gate tests.
- [ ] Metric series from `metric.recorded`, action outcomes, and approval rates; per-steward
  series with fixed windows for the app chart.

Later:
- [ ] Judge-adapter scorer (an adapter scores a result against the expected one).

## Decisions

## Questions

## Log
