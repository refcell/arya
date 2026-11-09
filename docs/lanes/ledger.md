# Lane: ledger

Owns `Sources/AryaCore`, `Sources/AryaLedger`, `Tests/AryaCoreTests`, and
`Tests/AryaLedgerTests`.

Goal: **the foundation every other lane writes to.** Shared value types, the `Ambient` source of
time, ids, and randomness, and an append-only, hash-chained ledger that survives crashes,
verifies in one pass, and projects into the state the runtime and app read. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md#the-ledger), decisions 0003, 0006, 0011, 0012, 0013.

## Backlog

M1:
- [x] `AryaCore` ids: `StewardID`, `RunID`, `EventID`, `ApprovalID`, `CaseID` (prefixed strings
  such as `st_`, `run_`, `ev_`), `Codable` as plain strings.
- [x] `Ambient`: clock, id generator, seeded RNG; `live`, `fixed(start:step:seed:)`, and
  `recorded(...)` variants; a test that two `fixed` ambients produce identical sequences.
- [x] Canonical JSON encoder (keys sorted by UTF-8 bytes, no whitespace, `/` unescaped) with
  golden tests, including unicode keys and nested arrays.
- [x] `Charter` (with `CharterBinding`, `Trigger`, `Policy`, `Limits`, `Scorer`, `GateConfig`,
  `Effort`) and `Case`, matching the JSON in ARCHITECTURE.md, with validation errors and golden
  fixtures. `GateChecking` protocol.
- [x] `Event` envelope and `Actor`; the write rule from decision 0012; golden test of one line.
- [x] Segment store: `ledger/000001.jsonl`, rollover at 64 MiB (configurable for tests),
  per-append `flock` with tail re-read, `fsync`.
- [x] Reader: iterate all events in order, from a `seq`, and follow new appends (for `tail` and
  the app).
- [x] `verify`: chain, `seq` continuity, `prev` links, envelope schema; reports the first bad
  line. Test tampering with one byte in a middle segment.
- [x] Torn-line repair on open: move bytes to a blob, truncate, append `system.repair`. Test by
  writing a partial line.
- [x] Two-process append test (spawn a child writer) proving no lost or interleaved lines.
- [x] Blob store `blobs/sha256/ab/<hex>`: put, get, exists; atomic write via temp file + rename.
- [x] Typed payloads for the ledger-owned event types (`run.*`, `action.*`, `approval.*`,
  `env.read`, `system.*`), each with a golden test; the rest live with their writers (0019,
  0022, 0023, 0024).
- [x] Projections: `LedgerProjection`, `Projected`, `rebuild`/`catchUp`, and `LedgerIndex`, with
  a test that rebuilt and incremental results are equal. Steward, run, and approval
  projections already live in the runtime (`StewardBook`, `RunBook`, `ApprovalBook`; 0028).

M2:
- [ ] Projections: metric series per steward, proposals, rehearsals, casebook versions.
- [ ] Projection cache in `cache/` with a header naming the last `seq`; delete-safe.

M3:
- [ ] Ledger query API for the app's ledger table: filter by steward, run, type, actor; page by
  `seq`.

## Decisions

- Ids are `PrefixedID` structs (`st_`, `run_`, `ev_`, `ap_`, `prop_`, `reh_`, `mem_`); generated
  bodies are 26-character ULIDs (48-bit ms time, 80 random bits, Crockford base32). `CaseID`
  has no prefix because case ids come from imported data (`case-0007`).
- Times are `Timestamp` (Int64 ms since the epoch), coded as `YYYY-MM-DDTHH:MM:SS.mmmZ` with
  pure calendar arithmetic, never a locale-dependent formatter.
- `Ambient` is a final class (stateful, lock-guarded). `fixed` ids reuse the last clock reading
  without advancing it. Every reading is logged for `drainReadings()`, the source of `env.read`.
  `recorded` never traps: mismatches are collected and answered from a fixed fallback.
- Canonical JSON goes through `JSONValue`: integers that fit `Int64` stay exact, integral
  doubles within 2^53 print without a fraction, others use Swift's shortest form (`1e-07`).
- `Charter` has no version field: versions are ledger facts (the `steward.*` payloads carry
  them). Optional sections decode to defaults (`policy.default` `ask`, triggers `[manual]`,
  effort `medium`, crew 1, limits 40/900/2000000, gate 1/0). `validate()` returns every issue
  with a field path instead of throwing on the first.
- The charter's scorer config is `ScorerSpec` and rubric checks are `RubricCheckSpec` (kind as
  a string) because `AryaEval` owns `Scorer` and `RubricCheck`. `Trigger` kinds: `interval`,
  `manual`, `message` (optional `from` person binding). Policy rules may name a `binding`; a
  binding-specific rule beats a general one.
- `GateChecking` takes `GateCheckRequest` and returns `GateCheckVerdict`, named so they do not
  clash with eval's `GateRequest`/`GateVerdict`; `RefusingGate` is the fail-safe default.
- `Event.payload` is a `JSONValue` object; typed access is `event.payload(as: P.self)` for any
  `EventPayload` (`static var type`). Writers build an `EventDraft` (type, actor, steward, run,
  payload); the store stamps `id`/`at` from `Ambient` and `seq`/`prev`/`hash` under the lock.
  `EventType` is an open string struct so unknown types still decode. Optional `steward` and
  `run` are omitted from the line when nil. `Actor.system` is `{"kind":"system","id":"arya"}`.
- Payload ownership follows decisions 0023 and 0024: the ledger owns `run.*`, `action.*`,
  `approval.*`, `env.read`, and `system.*`; memory's note (0019: `memory.*`, `routine.*` live
  in `AryaMemory`) is acknowledged. Ledger payloads match the runtime's existing JSON byte for
  byte (tests decode the runtime's exact lines) and carry no `v` of their own.
  Payload goldens regenerate with `ARYA_UPDATE_GOLDENS=1 just test AryaLedgerTests`.
- `LedgerStore(home:ambient:segmentLimitBytes:)` is the one writer: `append(_:)` takes one draft
  or a batch (one lock, one `fsync`). For each event it reads `ambient.now()` then
  `ambient.newID(EventID.self)`. A line longer than the segment limit still goes into a fresh
  segment by itself. Torn-tail repair runs on open and before every append; a complete final
  line that fails its hash or envelope check throws `LedgerStoreError.chainBroken` and the store
  refuses to write.
- File errors are `LedgerIOError` with a file name only (never a full path), so messages are
  safe to show and log.
- `LedgerReader` takes no lock and sees complete lines only (a final line without `\n` is
  skipped). `events(from:)`/`forEach(from:)` skip whole segments by peeking at first lines.
  `follow(after:interval:)` polls (200 ms default) and yields an `AsyncThrowingStream`; simple
  and portable, and appends are rare. `LedgerVerifier.verify()` returns a value (`ok`, count,
  head, first `Failure` with segment, line, offset, issue) rather than throwing on bad data.
- The multi-process test spawns `AryaLedgerWriter`, a tiny test-helper executable (not a
  product), two at a time alongside the test process, 150 appends each over 4 KiB segments.
- Projections fold `Event`s through `Projected<P>`, which refuses any event that is not the
  next `seq` with the matching `prev`; `catchUp` falls back to a rebuild when the ledger was
  replaced or truncated behind a projection (the hash at its `seq` changed).
- `Case.expected` stays a free-form `JSONValue` object because scorers read it by path.

## Questions


## Log
