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
- [x] Routine diff between versions (line-based, no dependencies) for the app's version view.
- [x] Routine execution for the `routine` action kind: run a shell routine in the run's workdir
  with a timeout, capture output for `action.executed`.
- [x] Routine proposals from `run/result` routed to `AryaEval` gates (through the protocol the
  runtime wires).

M3 (integration toward the end-to-end scenario):
- [x] `run/result.memories` intake: `MemoryIntake.notes` drafts `memory.added` by the steward
  with run provenance, ids from `Ambient`, duplicates of live notes skipped.
- [x] Run preparation: `RunPreparation.context` builds the snapshot (`run.started.memory`),
  live routine versions (`run.started.routines`), and composer inputs from the projections;
  `MemoryQuery.forRun` derives tags from the input text and case.
- [x] Listings for `arya memory --all` and the app: `MemoryProjection.allNotes` with retracted
  flags.
- [x] Blob store adoption: conform the ledger's blob store to `RoutineBlobStore` and drop the
  stub once `AryaLedger` ships it.
- [x] Read models for the app's Memory and Routines views: `RoutineLibrary.overview`, `diff`
  between any two stored versions, `MemoryProvenance.line`, `RoutineVersion.shortVersion`.
- [ ] Facade memory API with the workspace lane: `memory(steward:scope:)`, `retract`,
  `routines(steward:)`, `routineHistory`, `routineDiff` over the home's ledger and blobs.
- [x] Replay check helper: given a recorded `run.started.memory`, recompute the snapshot from
  the projection at that `seq` and report a divergence.

## Decisions

- Memory and routine payloads (`memory.*`, `routine.*`) live in `AryaMemory`, not `AryaLedger`
  (decision 0019): `AryaLedger` cannot import `AryaMemory`, and one owner avoids duplicate types.
- Projections apply `AryaLedger.Event` directly (`MemoryProjection(ledger:)`,
  `RoutineLibrary(ledger:)`), skipping other namespaces without decoding. `MemoryEventRecord`
  stays as the internal decoded form. Memory and routine payloads conform to `EventPayload`;
  `EventDraft.memoryAdded` attributes a note's event to its author.
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
- Routine content lives in the home's `AryaLedger.BlobStore`, which conforms to
  `RoutineBlobStore` (`put`, `getIfPresent`); tests use `InMemoryRoutineBlobStore`. Loading
  content re-hashes and rejects a corrupt blob.
- `RoutineDiff` is Myers' shortest edit script over lines (removals before additions in a
  change), with 1-based line numbers per side, unified-style hunks (default 3 lines of context),
  and `unified()` text. A missing final newline is not a change; `\r\n` is.
- A `routine` action's params: `name` (required), `version` (optional pin; must equal the
  live version), `args` (strings, `$1…`), `input` (stdin text). Only the live `sh` version
  runs; `prompt` routines are refused as `notExecutable`. `RoutineInvocation.prepare` resolves
  and hash-checks the content.
- `ShellRoutineRunner` runs `/bin/sh -c <content> <name> <args…>` with `posix_spawn` in the
  run's workdir, in its own process group, with a clean environment (fixed `PATH`, `HOME` and
  `TMPDIR` = workdir, `LC_ALL=C`, `ARYA_ROUTINE`, `ARYA_ROUTINE_VERSION`). The group is killed
  on timeout (default 60 s) and after exit, so no background child outlives the action. Each
  stream is capped (default 64 KiB) and flagged when truncated.
- `RoutineOutcome` (`status` exited/signaled/timed_out, exit code or signal, stdout, stderr,
  truncation flags) is the executor output for `action.executed` (exit 0) or `action.failed`.
  The runtime's action executor calls `RoutineRunning`; it is not sandboxed beyond the workdir
  and environment (roadmap: routine sandboxing under Later).
- Routine gating follows decision 0025: `RoutineProposals.intake` turns `run/result.routines`
  (as `ProposedRoutine`) into `routine.proposed` drafts (invalid ones are reported, duplicates
  by name in one result are rejected, an already proposed version is `unchanged`);
  `RoutineGatekeeper` checks a pending version through `RoutineGateChecking` and drafts the
  promotion only on a pass; `override` needs a human actor.
- Run-proposed notes are deduplicated against live notes by exact trimmed text; ids come from
  `Ambient.newID(NoteID.self)` so replay reproduces them. Provenance `event` is the event that
  carried the result when the runtime passes it.
- `MemoryQuery.forRun` tags = known live-note tags that appear as words in the input text
  (lowercased; words are runs of letters, digits, `-_:.`, trailing dots dropped), plus
  `case:<id>` for case runs, so a rehearsal of a corrected case sees its correction first.
- `MemoryReplay.check` compares a `run.started` event's `memory` snapshot and `routines` map with
  the projections rebuilt from events before it: a snapshot note that was not live, a routine
  version that differs from the live one, and a live routine missing from the record are
  divergences.

## Questions
- (from cli-e2e) `RoutineExecutionTests.timesOutAndKillsTheProcessGroup` failed once under full `just ci` (empty stdout) and passes alone; the 1 s timeout may fire before the shell prints under load.

## Log
- 2026-11-09: memory notes, payloads, live-note projection landed (f34e8ff).
- 2026-11-09: deterministic retrieval, `MemorySnapshot`, render landed (69f080a).
- 2026-11-09: fixed the intermittent `AryaDesignTests` crash by moving AppKit suites to the
  main actor (9d1f01b).
- 2026-11-09: corrections become attributed notes (6b0e5fb).
- 2026-11-09: memory types moved to core id types (aa8dcb6).
- 2026-11-09: routine library, payloads, `RoutineBlobStore` stub landed (1d31334).
- 2026-11-09: routine diff (Myers, unified hunks) landed (08fd695).
- 2026-11-09: shell routine execution, `RoutineInvocation`, `RoutineOutcome` landed (1da32d6).
- 2026-11-09: projections read ledger `Event`s; payloads conform to `EventPayload` (d82f2b3).
- 2026-11-09: routine proposals, `RoutineGatekeeper`, decision 0025 landed (77bd06a).
- 2026-11-09: run memory intake, `RunPreparation.context`, `allNotes` landed (d7bc2f0).
- 2026-11-09: fixed the runtime.md reference to decision 0025 (ef53890).
- 2026-11-09: ledger `BlobStore` adopted as `RoutineBlobStore`; `MemoryReplay.check` (5570258).
- 2026-11-09: routine overview, version diff, provenance read models (5f704c2).
