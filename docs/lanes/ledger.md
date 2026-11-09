# Lane: ledger

Owns `Sources/AryaCore`, `Sources/AryaLedger`, `Tests/AryaCoreTests`, and
`Tests/AryaLedgerTests`.

Goal: **the foundation every other lane writes to.** Shared value types, the `Ambient` source of
time, ids, and randomness, and an append-only, hash-chained ledger that survives crashes,
verifies in one pass, and projects into the state the runtime and app read. Design:
[ARCHITECTURE.md](../ARCHITECTURE.md#the-ledger), decisions 0003, 0006, 0011, 0012, 0013.

## Backlog

M1:
- [ ] `AryaCore` ids: `StewardID`, `RunID`, `EventID`, `ApprovalID`, `CaseID` (prefixed strings
  such as `st_`, `run_`, `ev_`), `Codable` as plain strings.
- [ ] `Ambient`: clock, id generator, seeded RNG; `live`, `fixed(start:step:seed:)`, and
  `recorded(...)` variants; a test that two `fixed` ambients produce identical sequences.
- [ ] Canonical JSON encoder (keys sorted by UTF-8 bytes, no whitespace, `/` unescaped) with
  golden tests, including unicode keys and nested arrays.
- [ ] `Charter` (with `CharterBinding`, `Trigger`, `Policy`, `Limits`, `Scorer`, `GateConfig`,
  `Effort`) and `Case`, matching the JSON in ARCHITECTURE.md, with validation errors and golden
  fixtures. `GateChecking` protocol.
- [ ] `Event` envelope and `Actor`; the write rule from decision 0012; golden test of one line.
- [ ] Segment store: `ledger/000001.jsonl`, rollover at 64 MiB (configurable for tests),
  per-append `flock` with tail re-read, `fsync`.
- [ ] Reader: iterate all events in order, from a `seq`, and follow new appends (for `tail` and
  the app).
- [ ] `verify`: chain, `seq` continuity, `prev` links, envelope schema; reports the first bad
  line. Test tampering with one byte in a middle segment.
- [ ] Torn-line repair on open: move bytes to a blob, truncate, append `system.repair`. Test by
  writing a partial line.
- [ ] Two-process append test (spawn a child writer) proving no lost or interleaved lines.
- [ ] Blob store `blobs/sha256/ab/<hex>`: put, get, exists; atomic write via temp file + rename.
- [ ] Typed payloads for every event type listed in ARCHITECTURE.md, each with a golden test.
- [ ] Projections: stewards (current charter, ready, paused), runs (status, parent, timing,
  cost), approvals (pending, decided); rebuilt from scratch and incrementally, with a test that
  both give equal results.

M2:
- [ ] Projections: metric series per steward, proposals, rehearsals, casebook versions.
- [ ] Projection cache in `cache/` with a header naming the last `seq`; delete-safe.

M3:
- [ ] Ledger query API for the app's ledger table: filter by steward, run, type, actor; page by
  `seq`.

## Decisions

## Questions

## Log
