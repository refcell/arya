# Lane: ledger and governance

Owns `Sources/AryaCore`, `Sources/AryaLedger`, `Tests/AryaCoreTests`, and
`Tests/AryaLedgerTests`, plus the governance read models in `Sources/Arya/Governance.swift`
(`Tests/AryaTests/GovernanceTests.swift`), coordinated with the workspace lane.

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
- [x] Projections: metric series per steward, proposals, rehearsals, casebook versions: owned by
  eval (`ProposalBook`, `RehearsalBook`, its metric-series item) per 0023/0028, on `LedgerProjection`.
- [x] Projection cache in `cache/` with a header naming the last `seq`; delete-safe.

M3:
- [x] Ledger query API for the app's ledger table: filter by steward, run, type, actor; page by
  `seq`.

M3 (extended by the lane):
- [x] Fast `seq`-addressed reads: `memchr` line splitting and skipping known lines in the first
  segment (5,000 events: tail read 1.5 s to 0.05 s). Perf probe: `ARYA_PERF=1 just test perf`.
- [x] (1) Faster full reads: `JSONParser` (AryaCore) replaces `JSONDecoder` in
  `LedgerLine.open`. 5,000 events, debug build, thread CPU time: full read 0.09 s (was about
  0.2 s CPU, 1.9 s wall on a busy machine), verify 0.10 s. Benchmark:
  `perfFullReadOf5000EventsIsUnderTarget` asserts < 0.3 s under `ARYA_PERF=1`.
- [x] (2) Readable `verify` report: `LedgerVerification.report` renders a headline plus
  `where`/`verified`/`meaning`/`next` lines, locale-free and golden-tested; adoption asked in
  workspace.md and cli-e2e.md Questions.
- [x] (3) Runtime books on `Projected`/`catchUp`/`ProjectionCache`: `RuntimeBook` and
  `sink.book(_:)` in AryaRuntime (logged in runtime.md). `ProjectionCache.current` now saves
  best effort, so an unwritable cache never fails a read.

M4:
- [x] (4) Signed checkpoints for compaction: design note in ARCHITECTURE.md
  ("Signed checkpoints and compaction").

Next (lane-extended, in order):
- [x] (5) `system.key.added` (`SystemKeyAdded`, golden) and `CheckpointKeys` (`keys/checkpoint.key`,
  0600, `ensure`, `rotate` signed by the old key, old file kept in `keys/retired/`); `KeyRing`
  folds the trusted keys and lists rejected ones.
- [x] (6) `system.checkpoint` (`SystemCheckpoint`, golden): `Checkpoints.build`/`record`/
  `check`/`trustedRing`; `LedgerVerifier` accepts a mid-chain start only with an anchoring
  checkpoint (`unanchored` issue otherwise) and checks every checkpoint (`badCheckpoint`).
- [x] (7a) `LedgerStore.compact(through:)` (verify first, append lock, archive never
  overwritten) and `LedgerVerifier.verifyArchive()`; anchors may be any covering checkpoint.
- [x] (7b) Projection digests and seeds: `Checkpoints.record(…, caches:)` writes
  `archive/seeds/<through>/<name>.json`; `ProjectionCache.current` seeds from the newest
  trusted, digest-matching seed on a compacted ledger, else throws `ProjectionError.archived`.
- [x] (8) Index-narrowed queries: `LedgerIndex.stewards` spans and `firstPossibleSeq`;
  `page`/`pageBackward(…, index:)` and `events(_:index:)` start at the run's or steward's first
  event (a stale index is safe). 50k probe: newest 50 of one steward 0.17 s (the probe's
  stewards start near seq 1, so this is the sieve cost; late runs skip their prefix).

Next (lane-extended toward M3.5 app parity, in order):
- [x] (9) Newest-first reads: `LedgerReader.newest(_:before:limit:)` scans segments newest to
  oldest, sieves lines from the bytes, and opens only the newest candidates; `pageBackward`
  uses it. 50k probe: newest 50 of one steward 0.008 s (was 0.17 s), newest 20 approvals
  0.007 s. Falls back to one forward pass if a segment's seqs are not contiguous.
- [x] (10) Per-steward counters in `LedgerIndex.stewards`: `counts` by type, `lastSeqByType`,
  and `openApprovals`, so the sidebar and status widgets read one cached index (old cache files
  fail to decode and rebuild).
- [x] (11) Filtered follow: `follow(_ filter:, after:interval:)` sieves appended lines and
  advances past the head each poll (the old `follow(after:)` call shape still works).
- [x] (12) `ProjectionCache.index()` (`cache/ledger-index.json`) and `events(at: seqs)`, a
  batch read that opens only the named lines.
- [ ] (13) A 50k-event probe for `verify` and cold `ProjectionCache.index()` (target: per-event
  cost of the 5k probe), and segment-parallel verify if it misses.
- [ ] (14) Export and import on top of checkpoints (ARCHITECTURE.md order of work): a steward's
  events plus the anchoring checkpoint as one bundle, checked on import.

Governance (restaffed 2026-11-09: trust, control, and audit, end to end; each item ships in
the app through app-views or app-shell Questions, with a snapshot state, tests, and an e2e step):
- [x] (G1) Roles and permissions: `policy.approvers` (who may approve which action kinds,
  per binding), enforced when an approval is granted and recorded as `approval.refused`;
  `Workspace.policySummary(steward:)` lists each binding's tool allowlist and actions with
  disposition, risk, and approvers. Approvers are `local` or person bindings until a people
  directory lands. UI and e2e asked in app-views.md and cli-e2e.md.
- [x] (G2a) Abort a running run (recorded, safe): `run.abort.requested`, the run driver stops
  the adapter and executes nothing, `Workspace.abortRun(_:reason:as:)`. App button and e2e
  asked in app-views.md and cli-e2e.md.
- [x] (G2b) Undo or compensate an approved action where its kind supports it, with the audit
  trail: `policy.undo`, `action.undo.requested`, `undoOptions(run:)`, `undoAction(...)`;
  app control and e2e asked.
- [x] (G3a) Data retention settings and plan: `system.retention.set`, `RetentionPolicy`,
  `RetentionPlan`, `retention()`/`setRetention(...)`; settings row asked in app-views.md.
- [ ] (G3b) Apply retention (archive eligible segments with a fresh checkpoint), once runtime
  and eval folds start from checkpoint seeds (Questions).
- [ ] (G4) Encryption at rest for the home (ledger, memory, credential references) with a
  Keychain-held key or file data protection, plus a migration.
- [ ] (G5) Signed audit export of a steward's ledger slice: JSON Lines plus a verification
  manifest, from the app.
- [ ] (G6) Then (13) and (14) above.

## Decisions

- (G1) Approver rules match like risk rules: kind and binding, then kind, then `*` and
  binding, then `*`; first listed among equals; `routine:<name>` matches a routine action.
  No rule means anyone who can see the approval may decide (existing charters keep working;
  the list is omitted from the charter JSON when empty). Denying is never role-gated: holding
  an action back is always safe. Questions are not role-gated. A refused grant appends
  `approval.refused` (`{approval, by, people, rule, note}`, actor the person) and leaves the
  approval pending; the runtime's `ApprovalBook` ignores the type. The facade keeps
  `approve(_:note:)` (the local user) and adds `approve(_:note:as:)`.
- (G2 abort) Abort is a ledger request, so any process (app, CLI) can abort a run another
  process (`arya serve`) is running: `run.abort.requested {reason?}` (actor: the person). The
  running `RunDriver` polls the ledger from a cursor every `questionPoll` (live runs only),
  sends `run/stop` (`user`), and shuts the adapter down 10 seconds later if it has not ended.
  An aborted run disposes and executes nothing it proposed (its wire lines are still
  recorded) and ends `run.finished` `stopped` ("Aborted: a person aborted the run."), or
  `run.failed` `aborted` when the adapter exits or times out first; a pending `host/ask`
  question is denied by `system`. When no live process holds the run's lease, the facade
  records `run.failed` `aborted` ("no process was running it") itself.
- (G2b undo) Undo is a compensation, never a ledger rewrite: `policy.undo` rules
  (`{action, binding?, with, note?}`, kind and binding first) say which executed kinds can be
  undone and by which kind. `undoAction(run:action:reason:as:)` records
  `action.undo.requested {action, compensation, reason?}` (actor: the person), then proposes
  `undo:<id>` (same binding and target, params `{undoes, params, previous}`) through the
  normal dispatcher, so policy, autonomy, approvers, and the binding's action list all apply;
  a binding that does not list `with` refuses it structurally. One undo per action.
- (G3 retention) Settings are ledger facts: `system.retention.set {steward?, days?}` (nil
  steward = home default, nil days clears; latest wins; `RetentionPolicy`). `RetentionPlan`
  takes the longest prefix of closed segments whose every event is older than the days that
  apply to it (its steward's, else the default; no setting keeps it), since compaction moves
  whole segments. Archiving is held back: 38 runtime and eval reads fold `events(from: 1)`, so
  moving segments would hide stewards, memory, and plans; `retention().blocker` says so and
  nothing moves. "Archive" is the only mode (nothing is ever deleted; compaction already
  archives). Applying retention waits on the question below.

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
- `ProjectionCache(home:)` stores `{"v":1,"name","seq","hash","value"}` per projection in
  `cache/<name>.json` (atomic writes). `current(_:name:)` loads, catches up, and saves; any
  unreadable or stale file is treated as absent, so deleting `cache/` is always safe.
- Query: `LedgerFilter` (steward, run, exact types, namespaces, actor kind and id; nil or
  empty matches all) with `LedgerReader.page(_:after:limit:)` (oldest first) and
  `pageBackward(_:before:limit:)` (opens at the newest). Cursors are `seq`s. Both stream the
  ledger; the `LedgerIndex` run spans can narrow a run query later if scans get slow.
- `Case.expected` stays a free-form `JSONValue` object because scorers read it by path.
- `JSONParser` gives exactly `JSONDecoder`'s `JSONValue` for every input (corpus, fixtures,
  seeded round trips, and byte-mutation fuzz pin it; `ARYA_FUZZ_ITERATIONS` searches longer).
  Its number rule: plain integers exact; other tokens via `Double`, integral values in
  ±2^63 become the exact decimal `int`; a token whose decimal has a fraction yet rounds to an
  integral `Double` goes to `JSONDecoder` itself (never written canonically). Two deliberate
  differences: nesting past `maxDepth` (128) and any raw NUL byte are errors. The writer
  refuses payloads deeper than `maxDepth - 1` (`LedgerError.payloadTooDeep`) so every
  written line reads back; no existing writer comes near that depth.
- Filtered reads go through `LineSieve`: per filter field, canonical-JSON needles
  (`"steward":"…"`, `"type":"…"`, actor `{"actor":{"id":"…"`, `"kind":"…"}`) found with
  `memmem`, plus the envelope `at` read from the first `"at":"`. Needles are necessary, never
  sufficient: passing lines still open and match in full, so payload decoys only cost time.
  Skipped lines are not hash-checked (verify is the integrity check); the first line after a
  `seq` skip is always opened to keep the contiguity check. `since` skips a segment when the
  next one's first `at` is before the bound, assuming `at` never steps back across a segment
  boundary; segments read are compared line by line.
- Checkpoint key material never comes from `Ambient` (its readings land in `env.read` on the
  ledger): new keys come from CryptoKit's system generator, or from the caller in tests. The
  key file is canonical JSON `{"algorithm","key","privateKey","v"}`. `KeyRing` trusts a first
  key only while no key is trusted and unsigned, and a later key only when `replaces` names a
  trusted key whose signature over the payload without `signature` checks; others go to
  `rejected`. `ensure` refuses (`notRecorded`) to record a stored key unsigned on a ledger
  that already trusts another.
- Checkpoints carry `keys` (every trusted public key) so a compacted ledger whose
  `system.key.added` events were archived still checks them; only the anchoring checkpoint's
  `keys` are trusted, and only entries whose id hashes from their key. Verify folds keys and
  collects checkpoints in its one pass, then checks signatures, live heads, and live segment
  digests; a checkpoint's key may be recorded after it (keys are never revoked).
  `LedgerVerification` gained `firstSeq` (default 1); `firstBadSeq` is the checkpoint's `seq`
  for `badCheckpoint` and the first live `seq` for `unanchored`.
- An anchoring checkpoint may sit past the cut (`SystemCheckpoint.anchors(firstSeq:)`): it
  lists a segment ending at the cut and its live head is checked, so a checkpoint at the head
  can anchor a cut at a segment boundary. `verifyArchive` checks only the segments the anchor
  lists before the first live event; after a second compaction, older archive files were
  vouched for by the earlier checkpoint, which is itself archived.
- Projection digests are SHA-256 of the canonical JSON of the cache file's `value`, computed
  from the file as `JSONValue` so the ledger lane needs no projection types. Only cache files
  exactly at the checkpoint's `through` (seq and hash) are digested; callers bring caches
  current first. Seeds live under `archive/` because `cache/` must stay delete-safe.
- Perf probes measure thread CPU time, not wall time, so a loaded machine does not make them
  flaky. Hot loops in `JSONParser` and `LedgerLine` use index loops and plain byte compares:
  tests run debug builds, where range patterns and generic slice algorithms cost metadata
  lookups per byte.

## Questions

- (G3) To apply retention, every `sink.events(from: 1)` fold in runtime and eval must start
  from a checkpoint seed (`ProjectionCache.current`) instead of the first event, or read the
  archive too. Asked in runtime.md and eval.md; until then retention plans but never moves.

- (from eval) Add `ScorerSpec.judge(rubric:, passThreshold:, adapter:)`? Eval has `AdapterJudge`.

## Log
- HANDOFF 2026-11-09 (governance session 1, ended near auto-compaction): (G1), (G2a), (G2b),
  (G3a) done and on main. Next: (G4) encryption at rest, then (G5) signed export, (G3b) when
  runtime/eval answer, then (13), (14). Facade code lives in `Sources/Arya/Governance.swift`
  (tests in `Tests/AryaTests/GovernanceTests.swift`); integration edits elsewhere are logged
  in workspace.md and runtime.md. UI, snapshot states, and e2e steps for every item are asked
  in app-views.md, app-shell.md, and cli-e2e.md Questions; check whether they landed and
  answer follow-ups. G4 note: the ledger reader sieves raw bytes (`LineSieve`, `memmem`), so
  per-line encryption would cost the read speedups; start with a design note weighing a
  Keychain-held key over memory, blobs, and credential references first versus file
  protection, then migrate. Run all four test targets with one build:
  `just test 'AryaCoreTests|AryaLedgerTests|AryaRuntimeTests|AryaTests\.'`.
  A "dirty tree" from `just publish` right after a commit is transient: `git status`, retry.
- 2026-11-09: (G3a) done: retention settings on the ledger and a whole-segment retention
  plan; archiving held back until history folds use checkpoint seeds (asked runtime, eval).
- 2026-11-09: (G2b) done: undo as a policy-gated compensation (`policy.undo`,
  `action.undo.requested`, `undoOptions`, `undoAction`).
- 2026-11-09: (G2a) done: abort a running run from any process (`run.abort.requested`,
  `RunFailureReason.aborted`, `abortRun`); runtime integration noted in runtime.md.
- 2026-11-09: lane restaffed as ledger and governance. (G1) done: `policy.approvers`,
  `approval.refused`, `approve(_:note:as:)`, `policySummary(steward:)`, decision 0045. App
  section and e2e step asked in app-views.md and cli-e2e.md.
- HANDOFF 2026-11-09 (third session, ended near auto-compaction): backlog (5a)-(12) done and on
  main. Next: (13), then (14). Notes: filtered reads go through `LineSieve` (needles are
  necessary, never sufficient; skipped lines are not hash-checked). `newest(_:before:limit:)`
  backs `pageBackward`. Checkpoints carry `keys`; anchors may sit past the cut
  (`SystemCheckpoint.anchors`). Seeds live in `archive/seeds/<through>/`. `just publish` often
  needs several push retries under load (10-40 min); a "dirty tree" right after a commit was
  transient each time: run `git status`, then publish again. Never open the app window.
- 2026-11-09: (11), (12) done: filtered follow, `ProjectionCache.index()`, `events(at:)`.
- 2026-11-09: (10) done: per-steward counters in `LedgerIndex`; backlog extended (11), (12) (a00db23).
- 2026-11-09: (9) done: newest-first reads; `pageBackward` 20x faster on 50k events (21faa2f).
- 2026-11-09: (8) done: index-narrowed queries; backlog extended with (9) and (10) (a8fe3cf).
- 2026-11-09: (7b) done: projection seeds and seeding on compacted ledgers (89b5dd0).
- 2026-11-09: (7a) done: compaction to `archive/`, `verifyArchive`, covering anchors (6e8e9bc).
- 2026-11-09: (6) done: `system.checkpoint`, `Checkpoints`, verify anchoring (`unanchored`,
  `badCheckpoint`) with report text. Verify of 5,000 events 0.11 s CPU (ef55a14).
- 2026-11-09: (5) done: `system.key.added`, `CheckpointKeys`, `KeyRing` (dd8bbe0).
- 2026-11-09: (5a) done: sieved filtered reads, `since`/`until`, `events(since:)`, typed
  reads; 50k filtered scan 0.09 s CPU (9930fc1). Read API offered in workspace.md Questions.
- HANDOFF 2026-11-09 (second session, ended near auto-compaction): backlog (1)-(4) done and
  on main. Next is (5a) (app-parity read speed), then (5)-(8), all from the ARCHITECTURE.md checkpoint note. Notes:
  measure perf with thread CPU time (`ARYA_PERF=1 just test perf`); wall time is meaningless
  under machine load. Debug-build hot loops: avoid range patterns, `for in 0..<n`, and generic
  slice algorithms (see the decision on perf). `JSONParser` changes must keep
  `JSONParserTests` green; search longer with `ARYA_FUZZ_ITERATIONS=40000`. Runtime books use
  `RuntimeBook.cacheName` (bump its suffix on any fold change). Open asks: workspace.md
  (report lines on `LedgerCheck`, `sink.book` in `Workspace.runBook`), cli-e2e.md (print the
  report). Machine rules: `just` recipes share 2 CI slots; full `just ci` only inside
  `just publish`; never broad process kills.
- 2026-11-09: (4) done: checkpoint and compaction design note; backlog extended (5)-(8).
- 2026-11-09: (3) done: runtime books served from `cache/` (approved integration edit).
- 2026-11-09: (2) done: `LedgerVerificationReport`, `segments` and `firstBadSeq` on
  `LedgerVerification`, public inits for its `Location` and `Failure`.
- 2026-11-09: (1) done: `JSONParser` and envelope building without `JSONDecoder`; full
  read of 5,000 events 0.09 s CPU in debug.
- 2026-11-09: ids, Timestamp, Ambient, JSONValue, canonical JSON landed in AryaCore (5fdc638).
- 2026-11-09: Charter, Case, GateChecking with validation and goldens (5b7d61a).
- 2026-11-09: Event envelope, Actor, EventType, line sealing (decision 0012), EventPayload
  and ledger-owned payloads (2a48f1f).
- 2026-11-09: run.*, action.*, approval.* payloads owned here (0024); ProposedAction moved to
  AryaCore (93c62fe).
- 2026-11-09: LedgerStore (flock appends, rollover, torn-line repair) and BlobStore (d6b8f0c).
- 2026-11-09: LedgerReader with follow stream, LedgerVerifier (c725446).
- 2026-11-09: multi-process append test with the AryaLedgerWriter helper (99f6cf4).
- 2026-11-09: LedgerProjection, Projected, rebuild/catchUp, LedgerIndex (0028); M1 done
  (e1322ae). Interfaces for the ledger-backed EventSink are noted in workspace.md.
- 2026-11-09: ProjectionCache (8cd1de0); M2 done (eval owns its projections).
- 2026-11-09 (cli-e2e, lane paused): `Ambient.fixed` and `recorded` start `lastMillis` at their
  start time, so an id made before the first `now()` no longer has time zero and sorts by time;
  `fixedIDsMadeBeforeTheFirstReadingCarryTheStartTime`.
