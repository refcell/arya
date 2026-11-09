# Decisions

Short records of cross-lane decisions. Newest last. Format: number, date, decision, why. To
change a decision, add a new entry that supersedes it; do not rewrite old entries.

### 0001 — 2026-11-09 — One Swift package, zero dependencies

Core, CLI, adapters, and the macOS app are one Swift 6 package built with SwiftPM. No
third-party packages; Foundation, CryptoKit, SwiftUI, and AppKit only. Tests use Swift Testing.
Why: one toolchain, a slim repo, and builds that work with only the command-line tools installed
(no Xcode).

### 0002 — 2026-11-09 — The app is a SwiftPM executable bundled by script

`AryaApp` is an executable target; `etc/scripts/bundle-app.sh` wraps it into `Arya.app` with
`etc/app/Info.plist` and an ad-hoc signature. Why: no `.xcodeproj` to maintain or merge, and
Xcode is not required.

### 0003 — 2026-11-09 — The ledger is a hash-chained JSON Lines file

One global, append-only ledger of JSON lines, segmented by size, guarded by an advisory lock,
each event chained by SHA-256. All other state is a projection. Why: plain files are durable,
diffable, and easy to replay; a single chain makes audit trivial.

### 0004 — 2026-11-09 — Adapters speak JSON-RPC 2.0 over stdio, one process per run

See [PROTOCOL.md](PROTOCOL.md). Why: language-neutral, trivial to implement, crash-isolated, and
every message is recordable.

### 0005 — 2026-11-09 — Agents propose, arya disposes

Adapters never perform external side effects; they return proposed actions in `run/result`, and
arya applies the charter's policy (`auto`, `ask`, `deny`) and executes them. Why: it is the only
way to enforce approval gates and audit actions without trusting each harness.

### 0006 — 2026-11-09 — All non-determinism flows through `Ambient`

Clock readings, generated ids, and random numbers come from `AryaCore.Ambient` and are recorded.
Replay uses a recorded ambient and a `ReplayAdapter`. Why: deterministic replay is a core
promise. (The CEO draft called this type `Environment`; see 0011.)

### 0007 — 2026-11-09 — Charters, casebooks, and profiles are JSON

Human-authored files are JSON (casebooks are JSON Lines). Why: no parser dependency; the app
provides editors.

### 0008 — 2026-11-09 — Vocabulary

steward, charter, binding, run, case, casebook, rehearsal, proposal, gate, routine, memory,
approval, crew, ledger, effort (see [AGENTS.md](../AGENTS.md#glossary)). Use these words in code,
UI, and docs.

### 0009 — 2026-11-09 — CI is staged in etc/ci

The push credential lacks workflow scope, so `.github/workflows` is not written. `etc/ci/` holds
the workflow, ready to copy once a credential with that scope exists.

### 0010 — 2026-11-09 — Executable targets are not named after their products

The `arya` CLI lives in `Sources/AryaCLI`, the adapters in `Sources/AryaFakeAdapter` and
`Sources/AryaExecAdapter`; the products keep the names `arya`, `arya-fake-adapter`, and
`arya-exec-adapter`. Why: `Sources/arya` and `Sources/Arya` are the same directory on a
case-insensitive file system, the macOS default.

### 0011 — 2026-11-09 — `Environment` is named `Ambient`

The type that supplies clock, ids, and randomness is `AryaCore.Ambient` (`Ambient.live`,
`Ambient.fixed(...)`, `Ambient.recorded(...)`). Why: the app imports both SwiftUI and the arya
modules, and SwiftUI's `Environment` property wrapper would make every use ambiguous. The same
rule applies to other names SwiftUI or Foundation export (`Binding` becomes `CharterBinding`).

### 0012 — 2026-11-09 — The ledger hash covers the written bytes

The writer canonically encodes the event without `hash`, hashes those bytes, and writes them with
`,"hash":"<hex>"}` appended in place of the final `}`. Verification strips the fixed-length
suffix and never re-encodes. Why: re-encoding on verify would tie chain validity to number and
string formatting details of a JSON encoder version.

### 0013 — 2026-11-09 — Lock per append; one scheduler

Every append takes `ledger.lock`, re-reads the tail for `seq` and `prev`, writes, `fsync`s, and
releases. Only the process holding `scheduler.lock` fires triggers. Why: the CLI, the app, and
`arya serve` all write (approvals, corrections), and a lifetime writer lock would block the app
whenever a run is in progress.

### 0014 — 2026-11-09 — Tools reach systems only through the binding proxy

`run/start.tools` points to `arya binding-proxy`, which exposes only a binding's `read` tools and
records every call and result. Write tools are never handed to a harness. Built-in harness tools
are confined to a per-run `workdir` where the harness allows it and reported as the `sandbox`
capability. Why: without a proxy, "agents propose, arya disposes" would rely on each harness's
good behavior, and tool results would not be recorded for replay and rehearsal.

### 0015 — 2026-11-09 — Rehearsal never executes actions or reads live systems

Rehearsal answers tool reads from the case's recorded context and records every disposition
without executing it. An unanswered read fails the call and marks the case `leak`. Why: past
work must be judged on what was known at the time, and rehearsing must never change the world.

### 0016 — 2026-11-09 — Crews run after the parent and report to a join run

`run/result.delegations` become child runs (bounded by `crew.maxParallel`, depth 1), followed by
one join run of the parent that receives the children's results. The draft's streamed
`delegation` event kind is removed. Why: a one-shot result protocol cannot return child results
into a running harness, and command-line agents parsed at exit cannot take mid-run input.
`host/delegate` for in-run crews is listed under Later in the roadmap.

### 0017 — 2026-11-09 — Gates tolerate sampling noise explicitly

A gate compares the candidate's mean case score with the baseline (latest rehearsal of the live
version on the same casebook version) within `gate.tolerance`, and fails on a case that passed
in every baseline sample and fails in every candidate sample, over `gate.samples` runs per case
(default 1, tolerance 0). Why: agents are stochastic; "no case may ever regress" with one sample
would make gates flaky, while hidden tolerances would make them meaningless.

### 0018 — 2026-11-09 — Policy defaults to `ask`

A charter's `policy.default` is `ask` when omitted, so an action kind no rule mentions is held
for approval, never executed silently. Why: guardrails should fail safe.
