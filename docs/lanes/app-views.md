# Lane: app-views

Owns `Sources/AryaApp/Features`.

Goal: **every part of a steward's life visible and correctable from the app.** The feature views
that live inside the shell: run stream, approvals, ledger, memory, routines, rehearsals,
metrics, and the charter editor. All visuals come from `AryaDesign`; no raw colors or font sizes
([STYLE.md](../STYLE.md)).

## Backlog

M3 (start now against the app-shell stub workspace):
- [ ] Run stream: messages, tool calls and results, decisions, proposed actions, status, live.
- [ ] Approval queue and approval cards: action, rationale, target, approve and deny with the
  local user recorded as actor.
- [ ] Ledger table: filter by steward, run, type, actor; event detail; Verify button with result.
- [ ] Changes tab: proposals with gate results, accept, reject, override (recorded).
- [ ] Memory view: notes with provenance, retract.
- [ ] Routines view: names, live version, history, version diff.
- [ ] Rehearsals view: per-case results, expected versus actual, correction, Mark ready.
- [ ] Metric chart: the steward's outcome metric over time against its target (Swift Charts).
- [ ] Charter editor: outcome, metric, guardrails, bindings, triggers, policy, effort; saving
  creates a proposal, never an in-place edit.
- [ ] Empty, loading, and error states for every view.

## Decisions

## Questions

## Log
