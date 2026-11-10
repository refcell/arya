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
- [x] (13) 50k probe (`perfVerifyAndColdIndexOf50000EventsScale`): verify 0.852 s and cold
  `index()` 0.941 s against 0.929 s for the 5k per-event cost times 50k (debug, CPU time);
  both linear, so segment-parallel verify is not needed.
- [x] (14) Export and import: the (G5) bundle is the export; `importAudit(from:as:)` checks
  it, recreates the steward from its latest charter with its live memory, and records
  `system.audit.imported`; "Import…" in app settings (snapshot `governance-retention`).

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
- [x] (G3b) Apply retention: `RetentionArchive.apply`, `applyRetention(as:)`,
  `system.retention.applied`, archive read-through in `LedgerReader`; "Archive now" in app
  settings (snapshot `governance-retention`). CLI asked.
- [x] (G4a) Encryption at rest: a Keychain-held home key seals event payloads (memory,
  runs, actions, approvals), blobs, projection caches, and seeds (`HomeEncryption`,
  `system.encryption.enabled`, `encryption()`/`enableEncryption(as:)`); blobs, caches, and
  seeds migrate on enable. CLI, settings row, and e2e asked.
- [x] (G4b) Re-seal history written before encryption: `Reseal.apply`, `resealHistory(as:)`,
  `system.ledger.resealed`; "Seal earlier events…" in app settings when any remain. CLI
  asked.
- [x] (G1-G4a in the app) Abort, Undo, policy and approvers, retention, and encryption
  shown in the app with snapshot states (`Features/Governance/`, hooks in StreamTab,
  InspectorView, AppSettingsView).
- [x] (G5) Signed audit export: `AuditExport.write`/`verify`, `system.audit.exported`,
  `exportAudit(steward:to:reveal:as:)`, `Workspace.verifyAudit(at:)`; "Export signed
  slice…" in the steward inspector (snapshot `governance-inspector`). CLI asked.
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
- (G4 encryption) Design. FileVault already encrypts the disk, and macOS file protection
  classes add nothing for a non-sandboxed process, so arya seals content itself: copies,
  backups, and other local users then see envelopes only. One 256-bit home key per home,
  generated by CryptoKit (never `Ambient`), kept in the login Keychain (`arya.home`, account
  the key id, readable after first unlock so a login-item `serve` works). The key id
  `hk_<24 hex>` hashes a label and the key. AES-256-GCM with keys derived by HKDF; the nonce
  is an HMAC of the context and the plaintext (synthetic IV), so sealing reads no randomness,
  replays and goldens stay byte-stable, and a nonce repeats only for identical input.
  What is sealed: the payload of every event that is not `system.*`, as
  `{"sealed":{"box","key","v":1}}`, with context `event|<id>|<seq>|<type>`. The envelope
  (seq, id, at, steward, run, actor, type, prev, hash) stays clear, so the raw-byte sieve,
  `newest`, `follow`, the index, the hash chain, `verify`, checkpoints, and compaction work
  unchanged and without the key; per-line encryption would have lost all of those. Blobs,
  cache files, and seeds are sealed files (`arya-sealed 1 <key>\n` + box; contexts
  `blob|<hex>`, `cache|<name>`); a blob's key stays the SHA-256 of its plaintext.
  Connection secrets were already Keychain-only; credential references (binding ids) are
  charter fields, so they are sealed with the steward events. Not sealed: envelopes, the
  setting file, run workdirs (scratch, owned by runtime), and events written before enabling.
  Wiring: `HomeEncryption.register(home:keys:)` (called by `Workspace.open`, default the
  Keychain store) makes every `LedgerReader`, `LedgerStore`, `BlobStore`, and
  `ProjectionCache` for that home seal and open by home path, so no call site can forget.
  The setting is `keys/encryption.json`; the store re-reads it per append, so a home enabled
  by another process seals at once. A locked home (no key) still verifies and lists
  envelopes (`forEachEnvelope`) but reads and appends throw `HomeEncryptionError.locked`:
  silently skipping sealed events would make folds lie. Migration on enable seals blobs and
  seeds in place and drops plaintext caches (delete-safe). Old events stay clear because
  their bytes are hashed and signed; re-sealing them is (G4b). Losing the key loses the
  sealed data: key export is a follow-up for the CLI.
- (G5 audit export) A bundle is a new folder (never overwritten): `events.jsonl` (the
  steward's lines byte for byte, so each line's own hash checks), `keys.jsonl` (every
  `system.key.added` line), `payloads.jsonl` only with `reveal` (opened payloads of sealed
  lines, `{payload, seq}`), and `manifest.json` (counts, first and last seq, the ledger head
  at export, SHA-256 of each file, the signer's key id and public key) signed with the
  checkpoint key over its canonical bytes without `signature`. `verify` needs nothing but the
  folder: digests, line hashes, seq order, the steward, and a signature by a key that
  `KeyRing` trusts from `keys.jsonl` (first key unsigned, rotations signed). The slice is
  not a chain (other stewards' lines are left out), so the head hash ties it to the ledger:
  anyone holding the ledger can compare it. Revealed payloads are vouched for only by the
  signature, since their boxes need the home key. The export itself is recorded as
  `system.audit.exported {steward, count, head, manifest, revealed}` (actor: the person).
- (G4b re-seal) A one-time rewrite of the live ledger under the append lock: every event
  keeps its id, time, `seq`, actor, and type; clear payloads that encryption seals now are
  sealed with the context of their own id and `seq`; hashes change from the first sealed
  event on. Checkpoints are re-signed with the home's checkpoint key against the new heads
  and segment digests (refused when one is signed by a key this home does not hold). The
  staging copy is verified line by line as it is written and swapped in with one atomic
  directory exchange (`RENAME_SWAP`); the clear copy is then removed, which is the point of
  the operation and why the app asks first. The old-to-new hash map `{"v":1,"map":[[seq,
  old, new]]}` goes to a blob named by `system.ledger.resealed {through, previousHead,
  sealed, checkpoints, map, key}`, so audit exports and outside copies taken before stay
  traceable. Projection caches are dropped (they name old hashes) and rebuild. A compacted
  ledger is refused: archived segments are vouched for by digests a rewrite would break.
- (14 import) Import builds on the signed export instead of a second bundle format: the
  manifest's signature and `keys.jsonl` stand in for the anchoring checkpoint (the signer is
  the home's checkpoint key either way). Importing re-records state, it does not splice
  lines: the target ledger has its own chain, so the steward's latest charter becomes
  version 1 here, its live memory notes are re-added (actor: the importing person), and
  `system.audit.imported {steward, count, head, manifest, key, notes}` names the source.
  Runs, approvals, and metrics stay in the export as evidence. A sealed charter needs a
  revealed export; sealed notes are skipped. Refused when the bundle does not check or the
  steward id already exists.
- (G3 retention) Settings are ledger facts: `system.retention.set {steward?, days?}` (nil
  steward = home default, nil days clears; latest wins; `RetentionPolicy`). `RetentionPlan`
  takes the longest prefix of closed segments whose every event is older than the days that
  apply to it (its steward's, else the default; no setting keeps it), since compaction moves
  whole segments. "Archive" is the only mode (nothing is ever deleted).
- (G3b apply retention) Unblocked inside the ledger instead of waiting on 43 runtime and eval
  call sites: `LedgerReader` reads `archive/` segments older than the first live one before
  the live ones (`archive: true` by default), so every history fold from `seq` 1 still sees
  every event after retention runs. Live-only readers pass `archive: false`: the verifier,
  checkpoints, compaction, `CheckpointKeys`, and the retention plan (`liveSegments()`). The
  projection cache reads through too; its checkpoint seeds remain the fallback when the
  archive itself is moved off the machine. `RetentionArchive.apply` records a checkpoint at
  the head (seeding current caches), compacts through the plan, and records
  `system.retention.applied {segments, through, checkpoint}`. What retention buys now is a
  small live ledger for the verifier, newest reads, follow, and appends; history reads cost
  the same as before. `retention().blocker` is always nil now (kept for compatibility).

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

- (from app-views) Review #12: the run Undo button (GovernanceViews) should be hidden when the run applied nothing: read `runFacts(run:).actionsApplied == 0`, or leave drafted actions out of the undo options. The run header now reads "Dry run: would have …" for these runs.

- (G3) To apply retention, every `sink.events(from: 1)` fold in runtime and eval must start
  from a checkpoint seed (`ProjectionCache.current`) instead of the first event, or read the
  archive too. Asked in runtime.md and eval.md; until then retention plans but never moves.

- (from eval) Add `ScorerSpec.judge(rubric:, passThreshold:, adapter:)`? Eval has `AdapterJudge`.
- (from connect) FYI: added optional `name` and `role` to person `CharterBinding`s
  (omitted when unset, golden fixtures unchanged) with `PersonBindingTests`.
- (from eval) FYI: added optional `CaseContext.plan` in core (omitted from JSON when empty).
- (from eval) New eval event `case.reviewed` {casebook, case, verdict agreed|skipped}; PROTOCOL?
- (from runtime) Integration edit (decision 0056): `ActionExecuted.dryRun` (true or absent) so a dry run reads as drafted, not done; `Governance` undo treats a drafted undo as not executed.
- (from runtime) Integration edit (decision 0057): `LedgerReader.scanLines` resumes tail reads from `LineMarks` (a line start per 1 MiB chunk, process-wide); trusted only after a newline and still checked by `expectFirst`, forgotten on `RescanSegment`. Test `tailReadsSurviveARewrittenSegment`. Warm tail read on 50k events: 29 ms → 2 ms.
- (from eval) New event `checks.built` (steward, payload: version, checks, added, removed).


## Log
- 2026-11-10: HANDOFF (this session retires). State: the governance backlog is complete and
  on main: G1-G4a in the app, G5 signed export, G3b archive, (13) 50k probe, (14) import, G4b
  re-seal, and now the governance CLI (per the CEO, taken from cli-e2e):
  `Sources/AryaCLI/GovernanceCommands.swift` with `arya steward policy`, `undo`, `retention`
  (+ `apply`), `encryption [--enable] [--reseal]`, `export --signed` (+ `export verify`, exit
  1 when it does not check), and `import`; backend calls appended to `WorkspaceBackend.swift`,
  one-line hooks in `Commands.swift`, `CLI.swift`, `Backend.swift`. Tests:
  `Tests/AryaCLITests/GovernanceCommandTests.swift` (parse, policy, retention, export, verify,
  tamper, import into a second home). e2e group `governance`, steps 51-58, all ok; step 37
  (MSG-203 crew, "crew children 2, no join run") fails on main and is not from this lane, noted
  for cli-e2e. Open for whoever picks this lane up: (a) G4b re-seal refuses compacted
  ledgers by design (decision 0048 notes); (b) the 50k cold index is 0.941 s against a 0.929 s
  target, within noise but worth a look if the home grows; (c) the app's export and import
  rows have no snapshot of an error state. Read the Backlog, decisions 0048 onward, and
  ARCHITECTURE.md "Signed checkpoints and compaction" first.
- 2026-11-10: Visual check after the app-shell settle fix: `governance-run` shows Undo 1 in
  the run header above the new split work pane (conversation left, Tools/Diff/Log/Output
  right); `governance-retention` shows encryption on with "Seal earlier events…" next to
  1612 earlier clear events. Moves points (1) and (3).
- 2026-11-10: (G4b) done locally: re-seal earlier clear history (chain rewrite, re-signed
  checkpoints, hash map blob) and a "Seal earlier events…" control in settings. Not
  published (holding for the CEO order); snapshot after the app-shell settle fix.
- 2026-11-10: b79a593 (G3b, 13, 14) published out of the CEO order: I read "the lane before
  you has landed" as runtime (#6, 8ca2ec1), but the order is strictly sequential from #1.
  Holding further publishes until app-views, cli-e2e, workspace, app-outcome, and runtime
  land; no full-suite or perf runs meanwhile. G4b continues locally.
- 2026-11-10: batch of three commits (G3b retention, (13) probe, (14) import) rebased on
  origin/main 07401a4 and green on AryaLedgerTests, AryaTests, and AryaAppTests; held for
  the CEO publish order (governance is 7th, after runtime). The governance hooks survived
  the split work pane (StreamTab, InspectorView, AppSettingsView). Snapshots re-render after
  the app-shell settle fix lands.
- 2026-11-10: (14) done: import a steward from a checked audit export (charter, live
  memory, provenance event) and "Import…" in app settings. Visual check:
  `governance-retention` shows the import row with the last import; moves point (3).
- 2026-11-10: (13) done: the 50k probe meets the 5k per-event target for verify and a cold
  index; no parallel verify. Committed locally (publish batched).
- 2026-11-10: (G3b) done: retention archives for real. `LedgerReader` reads archived
  segments first, so history folds are unaffected; `applyRetention` checkpoints, compacts,
  and records `system.retention.applied`; app settings show the eligible plan with "Archive
  now" and what is already archived. Committed locally; publish held for the CI queue and
  batched. Visual check: `governance-retention` (dark and light) read; moves point (3) real
  controls.
- 2026-11-10: reviewer VC24 fixes in the governance UI: the abort confirm is a quiet button
  in the negative tone (no orange); `ask` chips are neutral ink, approvers plain names
  ("Sam, you"), risk on the risk scale (low muted, medium amber, high red); "Anything not
  listed: ask"; undo rows drop the action id; the run-controls fixture shows a run title.
  Visual check: `governance-run-controls`, `governance-inspector`, `governance-policy`
  PNGs read; moves point (3) real controls.
- 2026-11-10: (G5) done: signed audit export (bundle, keyless verify, ledger record) and an
  export control with its last result in the steward inspector. Visual check: snapshot
  `governance-inspector` shows the Audit row with a verified export; moves point (3) real
  controls.
- 2026-11-10: governance visible in the app (governance-owned `Features/Governance/`):
  Abort (live runs, Command-period, with an abort question) and Undo (executed actions,
  undo list) in the run header; tools, actions with decision, risk, and approvers, the
  approver rules, and per-steward retention in the steward inspector; home retention with
  its plan and encryption at rest (Encrypt with a confirm) in app settings. Snapshot states
  `governance-inspector`, `governance-run`, `governance-run-controls`, `governance-policy`,
  `governance-settings`; the triage example gains `policy.undo` (label → unlabel) so the
  demo run shows Undo. Visual check: `just snapshot` PNGs read; moves point (3) real
  controls (compact, keyboard-hinted Abort ⌘., Undo with count) and (2) density (the
  inspector's policy block is dense mono rows, no empty panes).
- 2026-11-09: Paused for the night (user order) after (G4a) landed. Next: (G5) signed audit
  export (plan: `AuditExport` writes the steward's raw lines, the `system.key.added` lines,
  an optional `payloads.jsonl` of opened payloads, and a manifest signed by the checkpoint
  key; `verify` checks line hashes, file digests, and the signature), then governance CLI
  commands in new files (policy, abort, undo, retention, encryption, audit; none of the
  earlier app or CLI asks had landed), then (G4b), (G3b), (13), (14).
- 2026-11-09: (G4a) done: encryption at rest for payloads, blobs, caches, and seeds with a
  Keychain-held key; envelopes stay clear so the sieve and keyless verify keep working.
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
