# Lane: workspace

Owns `Sources/Arya` and `Tests/AryaTests` (taken over from the runtime lane).

Goal: **every user flow is reachable through one facade.** `Workspace` opens an arya home and
wires `AryaLedger`, `AryaAdapters`, `AryaMemory`, `AryaRuntime`, and `AryaEval` together. It is
the only API the CLI (cli-e2e lane) and the macOS app (app-views lane) use. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md), decisions in [DECISIONS.md](../DECISIONS.md).

## Backlog

M1 (the facade still throws `unavailable` for these):
- [ ] A ledger-backed `EventSink` for the home, then stewards, runs, approvals, ledger read,
  and verify through the runtime.

M2 (top priority first):
- [x] Runtime-backed `AryaEval.CaseRunner` in `Sources/Arya` (the runtime cannot import eval):
  one run with trigger kind `case` for `request.caseItem`, tool reads answered from its
  `context.toolResults`, no action executed; returns the run id, a result shaped like the
  case's `expected`, and `leak` (`RuntimeCaseRunner`). Plugs into `CasebookRehearser`.
- [ ] cli-e2e facade additions: `charter(_ id:) -> Data` (live charter), `run(_ id:) ->
  RunDetail` (decisions and per-action dispositions), and the calls behind `casebook import`,
  `rehearse`, `correct`, `ready`, `metrics`, and `replay`.
- [ ] Effort (decision 0026): `effort(for:)` and `setEffort(_:for:by:)`, recording
  `steward.effort.set`; tell app-shell in its lane file once it lands.
- [ ] Routine wiring (decision 0025, from memory): feed `run/result.routines` to
  `RoutineProposals.intake`, gate with `RoutineGatekeeper` through eval's
  `RoutineGateChecking` conformance, and execute `routine` actions with
  `RoutineInvocation.prepare` + `ShellRoutineRunner` (output is `RoutineOutcome`).
- [ ] Observation API the app can subscribe to (new ledger events lead to a refresh), with no
  SwiftUI import in the facade.

M3:
- [ ] Restart recovery wiring on `open` (interrupted runs fail, pending approvals stay).
- [ ] Facade-level end-to-end test with the fake adapter that mirrors the M3 scenario.

## Decisions

- Inherits the runtime lane's facade decisions: ids are `String`, read models are facade-owned
  values, and a call whose backing module has not landed throws `WorkspaceError.unavailable`.
- Canonical `approval.requested` payload is the runtime's `{approval, kind, action}` with a
  full `ProposedAction` (project lead decision).

- `RuntimeCaseRunner` passes the charter to the run loop only when it differs from the live
  charter at the requested version, so live rehearsals record the live `charterVersion` and
  candidates record 0. The scored result is the whole `run/result` as JSON; a failed run scores
  against `{}` and keeps its run id.
- `Arya` depends on every library module (ledger, adapters, memory, runtime, eval); it is the
  one place they meet.

## Questions

- From ledger: everything for the ledger-backed `EventSink` has landed in `AryaLedger`:
  `LedgerStore(home:ambient:)` (`append(EventDraft)` or a batch, multi-process safe),
  `LedgerReader(home:)` (`events(from:)`, `follow(after:)`), `LedgerVerifier(home:).verify()`,
  `BlobStore`, typed payloads (0024), and `LedgerProjection`/`catchUp` for the books (0028).
  `RuntimeActor` maps 1:1 onto `Actor` and `RuntimeEventDraft` onto `EventDraft`.
- From app-views: the Routines view diffs routine versions and needs their bodies. Proposed
  default: `Workspace.routineContent(steward:name:version:) async throws -> String?` reading
  the blob for that version (nil when missing). The app's `FacadeFeatureWorkspace` then
  forwards it; until then the view says routine bodies are not available.
- Moved here from runtime: the eval `CaseRunner` (done), the cli-e2e facade additions,
  app-shell's effort selector, and memory's routine wiring (backlog items above).

## Log

- 2026-11-09: lane created; `Sources/Arya` and `Tests/AryaTests` move here from runtime
- 2026-11-09: `RuntimeCaseRunner` (runtime-backed `CaseRunner`) for eval rehearsals
