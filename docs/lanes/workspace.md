# Lane: workspace

Owns `Sources/Arya` and `Tests/AryaTests` (taken over from the runtime lane).

Goal: **every user flow is reachable through one facade.** `Workspace` opens an arya home and
wires `AryaLedger`, `AryaAdapters`, `AryaMemory`, `AryaRuntime`, and `AryaEval` together. It is
the only API the CLI (cli-e2e lane) and the macOS app (app-views lane) use. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md), decisions in [DECISIONS.md](../DECISIONS.md).

## Backlog

M2 (top priority first):
- [ ] Runtime-backed `AryaEval.CaseRunner` in `Sources/Arya` (the runtime cannot import eval):
  one run with trigger kind `case` for `request.caseItem`, tool reads answered from its
  `context.toolResults`, no action executed; returns the run id, a result shaped like the
  case's `expected`, and `leak`. Wired into `CasebookRehearser`.
- [ ] cli-e2e facade additions: `charter(_ id:) -> Data` (live charter), `run(_ id:) ->
  RunDetail` (decisions and per-action dispositions), and the calls behind `casebook import`,
  `rehearse`, `correct`, `ready`, `metrics`, and `replay`.
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

## Questions

## Log

- 2026-11-09: lane created; `Sources/Arya` and `Tests/AryaTests` move here from runtime
