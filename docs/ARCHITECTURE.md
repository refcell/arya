# Architecture

arya turns an agent harness into a **steward**: a persistent agent that owns an outcome, keeps a
complete record of what it did, and can only change itself through tested proposals. This
document describes the moving parts, the data they share, and the invariants that hold them
together. Terms are defined in the glossary in [AGENTS.md](../AGENTS.md#glossary). Cross-lane
decisions and their reasons are in [DECISIONS.md](DECISIONS.md).

## Goals

1. **Tracked.** Every trigger, prompt, adapter event, tool call, decision, action, approval, and
   metric lands in one append-only ledger. Nothing important lives only in memory or in a
   harness.
2. **Durable.** All state is a projection of the ledger. Kill the process at any point; on
   restart arya rebuilds state from the ledger and resumes or cleanly fails in-flight runs.
3. **Deterministic.** Given its recorded inputs, a run's own decisions are a pure function.
   `arya replay <run>` feeds the recorded inputs back and checks that the runtime emits identical
   events.
4. **Improvable.** Changes to a charter or routine are proposals. A proposal is rehearsed on the
   steward's casebook and only goes live if it does not regress the baseline score.
5. **Harness-agnostic.** arya never links a harness. Harnesses run behind adapters that speak
   the protocol in [PROTOCOL.md](PROTOCOL.md).
6. **Local-first.** Single user, one machine, plain files. No servers, accounts, or cloud.

## Modules

```
          AryaApp (SwiftUI)          arya (AryaCLI)
                  \                    /
                   Arya (Workspace facade)
                            |
                         AryaEval
                            |
                       AryaRuntime
                       /         \
              AryaAdapters     AryaMemory
                       \         /
                        AryaLedger
                            |
                         AryaCore           AryaDesign (UI tokens, used by AryaApp only)
```

| Module | Responsibility |
| --- | --- |
| `AryaCore` | IDs, `Ambient` (clock, id generator, seeded RNG), `Charter`, `Effort`, `Case`, shared value types, canonical JSON encoding, the `GateChecking` protocol |
| `AryaLedger` | `Event` envelope, hash chain, segmented file store with locking, blob store, typed payloads, projections (stewards, runs, approvals, metrics) |
| `AryaAdapters` | `Adapter` protocol, JSON-RPC stdio transport, process supervision, `FakeAdapter`, `ReplayAdapter`, adapter profiles, conformance suite |
| `AryaMemory` | memory notes with provenance and retrieval, routine library with content-addressed versions |
| `AryaRuntime` | steward lifecycle, triggers and scheduler, run loop, approval policy, action execution, crews, binding proxy |
| `AryaEval` | replay checker, casebooks, rehearsal, scorers, readiness, proposals and gates, outcome metric series |
| `Arya` | `Workspace`: opens a home directory and wires all modules; the only API the CLI and app use |
| `AryaDesign` | colors, type scale, spacing, and components from [STYLE.md](STYLE.md) |
| `AryaApp` | the macOS app |
| `AryaCLI` | the `arya` command |
| `AryaFakeAdapter`, `AryaExecAdapter` | the reference adapter executables |

Dependencies point downward only. `AryaEval` sits above `AryaRuntime` because it drives real runs
on recorded inputs. The runtime asks for gate results through the `GateChecking` protocol in
`AryaCore`, which `Arya` wires to `AryaEval`. Executables and the app import `Arya` only (plus
`AryaDesign` for the app, and `AryaAdapters` for the adapter executables).

## Home directory

`$ARYA_HOME`, default `~/Library/Application Support/arya`. The home path is read once, by the
CLI or app entry point, and passed down; library code never reads environment variables.

```
ledger/000001.jsonl         the ledger, segmented at 64 MiB, one event per line
blobs/sha256/ab/abcd…       content-addressed payloads too large for an event
casebooks/<name>.jsonl      cases, one per line (imported into blobs when used)
adapters.json               adapter profiles: command, args, effort mapping
cache/                      projections (charters, run index); safe to delete
ledger.lock                 advisory lock taken for each append
scheduler.lock              held by the one process that runs triggers
```

Only the ledger and blobs are authoritative. Everything in `cache/` is rebuilt from them.
Charters are authored as JSON files anywhere and recorded into the ledger by
`arya steward create` and `arya propose`; the file on disk is not read again afterwards.

## The ledger

Each line is one event:

```json
{"v":1,"seq":42,"id":"ev_01J…","at":"2026-01-01T12:00:00.000Z",
 "steward":"st_triage","run":"run_01J…","actor":{"kind":"steward","id":"st_triage"},
 "type":"run.decision","payload":{…},"prev":"9f2c…","hash":"51ab…"}
```

- **Chain.** The writer encodes the event without `hash` as canonical JSON (keys sorted by UTF-8
  bytes, no whitespace, `/` unescaped) into bytes `B`. `hash` is the lowercase hex SHA-256 of
  `B`, and the line written is `B` with its final `}` replaced by `,"hash":"<hex>"}`. A verifier
  strips that fixed-length suffix and hashes the remaining bytes plus `}`; it never re-encodes,
  so number formatting cannot break verification. `prev` is the previous event's `hash`; the
  first event's `prev` is 64 zeros. `seq` starts at 1 and has no gaps. `arya ledger verify`
  checks all of this.
- **Attribution.** `actor.kind` is one of `human`, `steward`, `adapter`, `system`, and every
  event has one. The local user is `{"kind":"human","id":"local"}`; other people are identified
  by their binding contact id (`person:alex`).
- **Appends.** A writer takes `ledger.lock` (`flock`), reads the last line of the newest segment
  to learn `seq` and `prev` (another process may have appended), writes one line, `fsync`s, and
  releases the lock. The CLI, the app, and `arya serve` can all write safely.
- **Repair.** A torn final line (no trailing `\n`, or invalid JSON) is detected on open, its
  bytes are moved to a blob, the segment is truncated, and a `system.repair` event records it.
  Any other chain break makes the ledger read-only until a person runs `arya ledger verify` and
  decides.
- **Event types** are namespaced:
  - `steward.*`: `created`, `charter.updated`, `effort.set`, `ready`, `paused`, `resumed`,
    `retired`
  - `run.*`: `started`, `input`, `adapter.event`, `tool.call`, `tool.result`, `decision`,
    `finished`, `failed`
  - `action.*`: `proposed`, `executed`, `failed`, `rejected`
  - `approval.*`: `requested`, `granted`, `denied`, `expired`
  - `memory.*`: `added`, `retracted`; `routine.*`: `proposed`, `promoted`, `retired`
  - `casebook.*`: `imported`; `case.*`: `corrected`
  - `rehearsal.*`: `started`, `case.scored`, `finished`; `proposal.*`: `created`, `gated`,
    `accepted`, `rejected`, `overridden`
  - `metric.recorded`, `env.read` (an ambient reading not already carried by an envelope),
    `system.repair`, `system.started`

Payload types are Swift `Codable` structs in `AryaLedger`, each with a golden-file test.

## Charters and cases

A charter is a versioned JSON document. Version numbers increase by one per accepted change.

```json
{"v":1,"id":"st_triage","name":"Issue triage",
 "outcome":"Every new issue in the tracker is labeled and routed within one hour.",
 "metric":{"name":"triaged_within_1h","unit":"ratio","direction":"up","target":0.95},
 "guardrails":["Never close an issue.","Ask before assigning to a person."],
 "bindings":[{"id":"tracker","kind":"mcp","command":"tracker-mcp","args":[],
              "read":["search","get"],"actions":["label","comment","assign"]},
             {"id":"person:alex","kind":"person","channel":"inbox"}],
 "triggers":[{"kind":"interval","everySeconds":900},{"kind":"manual"}],
 "policy":{"default":"ask","rules":[{"action":"label","decision":"auto"},
                                    {"action":"close","decision":"deny"}]},
 "adapter":"exec-default","effort":"medium",
 "crew":{"maxParallel":3},
 "limits":{"maxTurns":40,"timeoutSeconds":900,"maxCostMicros":2000000},
 "scorer":{"kind":"exact","fields":["decisions.choice","actions.kind","actions.target"]},
 "gate":{"samples":1,"tolerance":0.0}}
```

- `policy.default` is `ask` when omitted: an unknown action kind is never executed silently.
- `bindings[].read` lists the tools a harness may call during a run. `bindings[].actions` lists
  the action kinds arya may execute through that binding after policy and approval.
- Validation rejects unknown binding references, empty outcomes, and duplicate ids.

A case is one past unit of work:

```json
{"v":1,"id":"case-0007","input":{"kind":"case","text":"New issue: login page times out"},
 "context":{"toolResults":[{"tool":"tracker.get","input":{"id":"ISSUE-7"},"output":{…}}],
            "memory":[]},
 "expected":{"decisions":[{"choice":"bug"}],
             "actions":[{"kind":"label","target":"tracker:ISSUE-7"}]},
 "source":"imported from an export of closed issues"}
```

A casebook's version is the SHA-256 of its normalized content, so scores are comparable only
against the same casebook version.

## Runs

A run is a state machine driven by inputs:

```
trigger ─▶ run.started ─▶ adapter run/start ─▶ run.adapter.event* ─▶ run/result
                                                                       │
          run.finished ◀─ action.executed / approval.requested ◀─ policy check per action
```

1. A trigger (schedule, manual, case, message from a person) creates `run.started` with the
   charter version, routine versions, memory snapshot, adapter profile, and composed
   instructions the run will see.
2. The runtime starts a fresh adapter process and streams its events into the ledger as
   `run.adapter.event`. Tool calls go through arya's binding proxy (below) and are recorded as
   `run.tool.call` and `run.tool.result`.
3. The adapter returns a `run/result`: summary, decisions, proposed actions, delegations, memory
   notes, routine proposals, measurements. The runtime records decisions as `run.decision` and
   each action as `action.proposed`.
4. **Agents propose, arya disposes.** Each proposed action is classified by the charter's
   policy: `auto` actions execute through their binding or routine; `ask` actions become
   `approval.requested` and wait in the approval queue; `deny` actions are recorded as
   `action.rejected`. Executor output is recorded on `action.executed` or `action.failed`.
5. Memory notes and routine proposals from the result become `memory.added` and
   `routine.proposed` events; measurements become `metric.recorded`.
6. `run.finished` closes the run with status, cost, and counts. Approvals may still be pending;
   when granted later, the action executes and is linked to the run.

**Binding proxy.** The `tools` an adapter receives in `run/start` are not the real MCP servers.
Each points to `arya binding-proxy --run <id> --binding <id>`, a stdio MCP server that forwards
only the tools in `bindings[].read`, records every call and result, and, in rehearsal and
replay, answers from recorded results instead of the live system. Write tools are never exposed;
writes come back as proposed actions. A harness's own built-in tools (shell, file edits) are a
trust boundary arya cannot fully enforce: adapters run the harness in a per-run scratch `workdir`
and disable built-in write tools where the harness supports it, and say so in their capabilities.

**Durability.** On start, the runtime projects open runs. A run whose adapter process is gone is
marked `run.failed` with reason `interrupted` and, if its trigger is a schedule, re-queued.
Pending approvals survive restarts because they are projections. Exactly one process holds
`scheduler.lock` and fires triggers; others only start manual runs.

## Replay

Replay checks that the runtime is deterministic, not that the model is. Recorded inputs are:
envelope `id` and `at` values and `env.read` events (served by `Ambient.recorded`), adapter
messages (served by `ReplayAdapter`), tool results (served by the binding proxy), executor
output on `action.executed` and `action.failed`, and every event whose actor is `human`.
Everything else (decisions, dispositions, approval requests, memory and routine events, metrics,
`run.finished`) is derived. `arya replay <run>` re-runs the runtime against the recorded inputs
and compares the derived events it emits with the recorded ones, field by field. The first
mismatch is reported as a divergence with both versions; zero divergence is the pass condition.

## Rehearsal, proposals, and gates

- A **casebook** holds past cases (see above). `arya casebook import` records it into blobs and
  the ledger.
- A **rehearsal** runs the steward on each case with the case's recorded context: tool reads are
  answered from `context.toolResults` (an unanswered read fails the call and marks the case
  `leak`, never reaching the live system), and **no action is ever executed**: every disposition
  is recorded only. Each case is scored by the charter's scorer (exact match on chosen fields,
  or a rubric) into `rehearsal.case.scored`. Rehearsal runs are ordinary runs with trigger kind
  `case`, so they replay like any other run.
- People review rehearsal results case by case. A correction from anyone records
  `case.corrected` (optionally a new expected result) and a `memory.added` note attributed to the
  person, then the steward can be rehearsed again. A person marks the steward **ready**
  (`steward.ready`); only ready stewards take live triggers.
- A **proposal** is a new charter version or a new or edited routine, from a person or from a
  run. It is rehearsed against the casebook. The **baseline** is the latest finished rehearsal
  of the live version on the same casebook version. The gate passes when the candidate's mean
  score is at least the baseline minus `gate.tolerance`, and no case that passed in every
  baseline sample fails in every candidate sample (`gate.samples` runs per case, default 1).
  A person may override a failed gate; the override is a `proposal.overridden` event with the
  person as actor.

## Memory and routines

- Memory notes are short text records with provenance (run, event, author) and tags. Each run
  gets a retrieved subset (tags and recency first; nothing that needs a model), and the snapshot
  is recorded on `run.started` for replay. `memory.retracted` hides a note from future runs.
- Routines are files (shell scripts or prompts) stored as content-addressed blobs. A routine
  version is its content hash; the live version per name is a ledger projection. Stewards
  propose routines through `run/result`; they go live only through a passing gate. Running a
  routine is an action kind (`routine`), so it goes through policy and approval like any other.

## Crews

A run may fan out work: its `run/result` lists `delegations`. After the parent run finishes,
each delegation becomes a child run (`run.started` with `parent`), at most
`crew.maxParallel` at a time, using the parent's charter with the delegation's input. When all
children finish, the runtime starts one **join** run of the parent (trigger kind `join`) whose
input lists each child's summary, decisions, and proposed actions. Children never execute
actions themselves; their proposals are carried into the join run. Delegation depth is limited
to 1 in v1.

## Adapters

See [PROTOCOL.md](PROTOCOL.md). arya ships `arya-fake-adapter` (scripted, deterministic, used by
tests and the demo) and `arya-exec-adapter` (wraps any command-line agent through a profile in
`adapters.json`).

## The app

The app opens the same home through `Arya.Workspace` and observes the ledger for new events. It
has a left rail of stewards and their runs, a main pane with the run stream, a tab bar for
Changes, Ledger, Memory, Routines, and Rehearsals, a visible approval queue, and an effort
selector. Writes from the app (approvals, corrections, Mark ready) are ledger events with the
local user as actor. Visual rules are in [STYLE.md](STYLE.md).
