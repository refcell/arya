# Lane: memory

Owns `Sources/AryaMemory` and `Tests/AryaMemoryTests`.

Goal: **stewards that remember and turn repeated work into code.** Memory notes with provenance
that every run can see a deterministic slice of, and a versioned routine library that stewards
write for themselves and that only changes through gates. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md#memory-and-routines).

## Backlog

M1:
- [x] `MemoryNote` (text, tags, provenance: run, event, author) and its ledger payloads
  (`memory.added`, `memory.retracted`); projection of live notes per steward.
- [x] Deterministic retrieval: tags, then recency, capped by count and characters; the snapshot
  (note ids) is what `run.started` records. Golden tests.

M2:
- [x] Corrections become notes attributed to the correcting person.
- [x] Routine library: routines as content-addressed blobs, `routine.proposed`,
  `routine.promoted`, `routine.retired`; live version per name as a projection.
- [ ] Routine diff between versions (line-based, no dependencies) for the app's version view.
- [ ] Routine execution for the `routine` action kind: run a shell routine in the run's workdir
  with a timeout, capture output for `action.executed`.
- [ ] Routine proposals from `run/result` routed to `AryaEval` gates (through the protocol the
  runtime wires).

## Decisions

- Memory and routine payloads (`memory.*`, `routine.*`) live in `AryaMemory`, not `AryaLedger`
  (decision 0019): `AryaLedger` cannot import `AryaMemory`, and one owner avoids duplicate types.
- Until `AryaLedger` publishes `Event`, projections read `MemoryEventRecord` (seq, id, steward,
  run, type, payload bytes). The envelope converts to it; the record goes once that lands.
- Memory types use `AryaCore` ids (`NoteID` `mem_`, `StewardID`, `RunID`, `EventID`, `CaseID`).
- Note text is trimmed, non-empty, at most 4096 UTF-8 bytes. Tags are trimmed, lowercased,
  deduplicated, and sorted by UTF-8 bytes. Decoding validates the same way.
- A retracted note id stays retracted: a later `memory.added` with the same id is ignored, as is
  a duplicate add. Retracting an unknown id is a no-op.
- Provenance is `run`, `event`, optional `case` (corrections), and `author` (kind and id).

- Retrieval ranks by the number of query tags a note shares, then newest first (ledger `seq`),
  then id. Notes are taken in rank order up to `maxNotes`; a note that would pass
  `maxCharacters` (UTF-8 bytes) is skipped and smaller later notes may still fit. Defaults: 20
  notes, 4000 bytes. Untagged queries reduce to pure recency.
- `MemorySnapshot` (`{"v":1,"notes":[ids]}`) is what `run.started` records. Replay resolves it
  with `MemoryProjection.resolve`, which also finds notes retracted after the run started.
- `MemoryRetrieval.render` is the memory section of composed instructions (`Memory:` then one
  `- id [tags]: text` line per note).
- A correction note (`MemoryCorrections.note`) is authored by the correcting person (kind
  `human`), points at the `case.corrected` event, the case, and the rehearsal run if any, and is
  tagged `correction` and `case:<id>` so rehearsing that case can retrieve it by tag.
- A routine version is the lowercase hex SHA-256 of its UTF-8 content, which is also its blob
  key. Names are 1-64 bytes of `[a-z0-9_.-]` starting with a letter or digit, unique per
  steward. Languages: `sh` (executable through the `routine` action kind) and `prompt` (text
  only). Content is at most 256 KiB.
- `routine.proposed` carries name, version, language, bytes, a one-line summary (reason, else
  the first `#` comment, else the name), reason, and run; content lives only in the blob.
  `routine.promoted` names the version and optional proposal; `routine.retired` names the live
  version it retires.
- The library projection never applies a contradictory event (promoting an unproposed version,
  a duplicate proposal, retiring a non-live version); it records a `RoutineAnomaly` instead.
- Until `AryaLedger` ships a blob store, routines use `RoutineBlobStore` (put/get by SHA-256 key)
  with an in-memory implementation; loading content re-hashes and rejects a corrupt blob.

## Questions

## Log
- 2026-11-09: memory notes, payloads, live-note projection landed (f34e8ff).
- 2026-11-09: deterministic retrieval, `MemorySnapshot`, render landed (69f080a).
- 2026-11-09: fixed the intermittent `AryaDesignTests` crash by moving AppKit suites to the
  main actor (9d1f01b).
- 2026-11-09: corrections become attributed notes (6b0e5fb).
- 2026-11-09: memory types moved to core id types (aa8dcb6).
