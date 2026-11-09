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
- [x] `arya replay <run>`: rebuild recorded inputs (ambient, adapter messages, tool results,
  executor output, human events), drive the runtime with `ReplayAdapter`, and compare derived
  events field by field; divergence report with both versions. Test with an injected
  nondeterminism bug that replay catches.
- [x] Casebook format and import (JSON Lines), content-hash versions, `casebook.imported`.
- [x] Rehearsal: one run per case (trigger `case`), tools served from case context, no action
  executed, `leak` detection, `rehearsal.*` events, parallelism bounded and deterministic in
  ordering. `CasebookRehearser` plus the facade's `RuntimeCaseRunner` (case runs, sample + 1,
  live-charter detection, candidate routine, leak passthrough); gates are wired in the facade.
- [x] Scorers: exact match on chosen fields; rubric scorer (weighted checks on result fields).
- [x] Corrections (`case.corrected`) and readiness (`steward.ready`).
- [x] Proposals and gates: baseline lookup, samples, tolerance, per-case regression rule,
  override event. Table-driven gate tests.
- [x] Metric series from `metric.recorded`, action outcomes, and approval rates; per-steward
  series with fixed windows for the app chart.

- [x] Routine gate (decision 0025): `RoutineRehearsalGate` conforms to `RoutineGateChecking`.
- [x] Casebook projection from `casebook.imported` (names, versions, latest per name) and a
  `CasebookSource` over blobs, for `arya casebook list`, rehearsal, and gates.
- [ ] Rehearsal review model for the app: per case expected versus actual, score notes, leak,
  and corrections applied.

Later:
- [ ] Judge-adapter scorer (an adapter scores a result against the expected one).

## Decisions

- Eval uses core types directly: `JSONValue`, `CanonicalJSON`, typed ids, `Case`, `ScorerSpec`
  (built into a scorer by `makeScorer()`; an unknown rubric check kind throws), and
  `GateChecking`/`GateCheckRequest`/`GateCheckVerdict` (`Gate` refines `GateChecking`;
  `RefusingGate` is the default). Events go through the runtime's `EventSink` with an explicit
  `RuntimeActor`; blobs go through `EvalBlobStore` until the ledger's blob store lands.
- Stubs fail safe: replay and rehearsal throw `notImplemented` and the stub scorer fails every
  case.
- Replay compares derived events by position (type, then payload in sorted key order), never by
  `seq`, because a replay writes to a scratch ledger. `DivergenceFinder` is pure and landed
  ahead of the runtime-driven replayer.
- `RunReplayer` seeds a scratch sink with every event before the run, so the charter, memory and
  approvals are as they were. The adapter is a `ReplayAdapter` over the run's
  `run.adapter.event` lines (workdir taken from the recorded `run/start`), wrapped so a divergent
  host line ends the run instead of hanging; the executor answers from recorded
  `action.executed`/`action.failed`. Scratch events take the recorded envelope ids and times in
  order. Until `env.read` is recorded, other engine readings (approval ids, clock) fall back to a
  fixed ambient, so ids and timestamps inside payloads are renamed by first appearance before
  comparing. Adapter lines, `env.read` and human events are inputs and are not compared.
  Rehearsal runs replay in rehearsal mode from the stored casebook and, for a candidate, the
  proposal's charter.
- `GateRule` (pure, decision 0017): a missing baseline or differing case sets fail the gate; a
  `leak` case counts as failed in every sample and scores 0 in the mean. Scorer paths fan out
  through arrays (`actions.kind`), and an exact or rubric scorer with nothing to check fails.
- Casebooks: cases are sorted by id and a casebook's version is the SHA-256 of canonical JSON
  Lines (`CanonicalJSON`), so reordering or reformatting keeps the
  version. Lines are validated with `Case.load`; duplicate ids, `v` other than 1, and empty
  casebooks are rejected. The normalized casebook is stored as one blob whose hash equals the
  version; `casebook.imported` is attributed to the importing person (default `local`).
- Rehearsal: `CasebookRehearser` drives a `CaseRunner` (implemented by the runtime: one run with
  trigger kind `case`, tool reads from case context, no action executed) and a
  `CasebookSource`. Events (actor `system`) are recorded after all runs finish, in case-id order, so ledger
  order never depends on completion order. A runner error scores that sample 0 with a note; a
  leak scores 0 and marks the case. `rehearsal.*` payloads live in `AryaEval`, as memory's do.
- Rehearsal takes the charter to run (live or a proposal's candidate) and an optional
  `proposal`; `RehearsalBook` projects `rehearsal.*` events, and the gate baseline is the latest
  finished rehearsal with no proposal for the live version and casebook version.
- Proposals and gates: decision 0027. `ProposalDesk` creates (`proposal.created`), checks,
  overrides (person only, failed gates only), accepts, and rejects; `RehearsalGate` records
  `proposal.gated` with actor `system`. Closed (accepted or rejected) proposals refuse every
  further operation. Only charter proposals exist so far; routine proposals come next.
- Baselines are fresh only if they finished after the steward's latest configuration change
  (`steward.created`, `steward.charter.updated`, `routine.promoted`); rehearsals with a
  proposal or a candidate routine never serve as baselines. Charter and routine gates share
  `GateFlow`; a routine gate rehearses the live charter with `RoutineCandidate` in place and
  records `proposal.gated` with `routine`.
- Casebooks on disk: `CasebookBook` projects `casebook.imported` (every version, latest per
  name; re-importing identical content keeps the first record). `StoredCasebooks` loads a
  version from blobs and refuses content that no longer hashes to its version.
  `AryaLedger.BlobStore` conforms to `EvalBlobStore`.
- Metric series: `OutcomeMetrics.series` reads `metric.recorded` payloads as `{"metric",
  "value"}` (a `run/result` measurement), `action.executed|failed|rejected`, and
  `approval.granted|denied|expired`, per steward, into contiguous fixed windows aligned to
  multiples of the window width since the epoch (UTC days by default), empty windows included.
  Approval rate is granted over decided; `nil` when nothing was decided.
- Corrections: `Corrector` records `case.corrected` and a `memory.added` note (built with
  `MemoryCorrections.note`, pointing at the correction event), both with the person as actor.
  A new expected result produces a new casebook version, recorded as `casebook.imported` with
  `correctedFrom`; baselines on the old version no longer apply, by design.
- Readiness: `Readiness.markReady` records `steward.ready` (the runtime's event type, which its
  projection reads) with a person as actor and the reviewed rehearsal, casebook version, and
  mean score as evidence. It does not require a rehearsal: the person decides.

## Questions

- From memory: routine proposals need an eval conformance of `AryaMemory.RoutineGateChecking`
  (decision 0025): rehearse the live charter with `RoutineLibrary.candidateRoutines(for:)`.
- (from runtime) `metric.recorded` is live (decision 0030): decode with
  `AryaRuntime.MetricRecorded` (`metric`, `value`); live runs only, so say if rehearsals need it.
- (from workspace) `CaseRunRequest.routine` is honored: `RuntimeCaseRunner` runs the case with the candidate in place of the live version; gate wiring is next.
- (from adapters) For `arya replay`: `ReplayAdapter(ledgerPayloads:exit:)` builds the adapter from the run's `run.adapter.event` payloads in ledger order (nil if one is damaged); an `AdapterFactory` returning it drives the runtime unchanged, and any differing host line throws `AdapterError.replayDivergence` with both lines.

## Log

- 2026-11-09: interfaces `Replayer`, `Rehearser`, `Scorer`, `Gate` with stubs (8247b8d)
- 2026-11-09: `DivergenceFinder`, exact and rubric scorers, pure `GateRule` (6a59273)
- 2026-11-09: casebook format, content-hash versions, import via `EvalRecorder` (6ee26b3)
- 2026-11-09: eval adopts core `JSONValue`, `CanonicalJSON`, typed ids (c824b64)
- 2026-11-09: `CasebookRehearser` with bounded parallelism and `rehearsal.*` events (1a41c45)
- 2026-11-09: eval uses core `Case`, `GateChecking`, `ScorerSpec`, runtime `EventSink` (028a9f8)
- 2026-11-09: corrections (`case.corrected`, note, corrected casebook) and readiness (86e1c81)
- 2026-11-09: charters flow through rehearsal; `RehearsalBook` finds baselines (8f0f8a6)
- 2026-11-09: proposals (`ProposalDesk`, `ProposalBook`) and `RehearsalGate`, decision 0027 (e0c679e)
- 2026-11-09: per-steward outcome metric series with fixed windows (fabfc1e)
- 2026-11-09: routine gate (`RoutineRehearsalGate`) and the fresh-baseline rule (7bce5aa)
- 2026-11-09: stored casebook projection `CasebookBook`, `StoredCasebooks` (d1ecf71)
- 2026-11-09: replay engine `RunReplayer(sink:casebooks:)`, a `Replayer` whose
  `replay(run:) async throws -> ReplayReport` drives `RunEngine` on recorded inputs (36829d4)
