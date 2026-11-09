# Lane: memory

Owns `Sources/AryaMemory` and `Tests/AryaMemoryTests`.

Goal: **stewards that remember and turn repeated work into code.** Memory notes with provenance
that every run can see a deterministic slice of, and a versioned routine library that stewards
write for themselves and that only changes through gates. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md#memory-and-routines).

## Backlog

M1:
- [ ] `MemoryNote` (text, tags, provenance: run, event, author) and its ledger payloads
  (`memory.added`, `memory.retracted`); projection of live notes per steward.
- [ ] Deterministic retrieval: tags, then recency, capped by count and characters; the snapshot
  (note ids) is what `run.started` records. Golden tests.

M2:
- [ ] Corrections become notes attributed to the correcting person.
- [ ] Routine library: routines as content-addressed blobs, `routine.proposed`,
  `routine.promoted`, `routine.retired`; live version per name as a projection.
- [ ] Routine diff between versions (line-based, no dependencies) for the app's version view.
- [ ] Routine execution for the `routine` action kind: run a shell routine in the run's workdir
  with a timeout, capture output for `action.executed`.
- [ ] Routine proposals from `run/result` routed to `AryaEval` gates (through the protocol the
  runtime wires).

## Decisions

## Questions

## Log
