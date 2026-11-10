# Lane: adapters

Owns `Sources/AryaAdapters`, `Sources/AryaFakeAdapter`, `Sources/AryaExecAdapter`,
`Tests/AryaAdaptersTests`, and `docs/PROTOCOL.md`.

Goal: **any harness, one contract.** A typed client for the adapter protocol, a robust process
transport, a deterministic fake adapter every test uses, a replay adapter for `arya replay`, and
a reference adapter that wraps command-line agents. Design: [PROTOCOL.md](../PROTOCOL.md),
decisions 0004, 0014, 0016.

## Backlog

M1:
- [x] Protocol types: requests, responses, notifications, `RunEvent`, `RunResult`,
  capabilities, error codes; golden tests for every example in PROTOCOL.md.
- [x] Line-delimited JSON-RPC codec: framing, id matching, notifications, adapter-to-host
  requests, protocol errors on non-JSON stdout.
- [x] `Adapter` protocol (async): `initialize`, `start`, `send`, `stop`, `cost`, `shutdown`, an
  `AsyncStream` of messages; every message in both directions surfaced for recording.
- [x] Process transport: spawn with `Foundation.Process`, pipes, stderr capture to a blob
  writer, timeout handling (`run/stop`, then SIGTERM, then SIGKILL), exit detection
  (`adapter_exited`).
- [x] `FakeAdapter` (in-process) driven by a script: events and a result keyed by input text;
  can simulate delays, errors, crashes, and `host/ask`.
- [x] `arya-fake-adapter --script <file>`: the same script over stdio; script format documented
  in PROTOCOL.md.
- [x] Conformance suite (`AdapterConformance`) run against `arya-fake-adapter` by default and
  `ARYA_ADAPTER_CMD` when set.

M2:
- [x] `ReplayAdapter`: serves recorded `run.adapter.event` messages in order, fails loudly when
  the runtime sends something the recording did not contain.
- [x] Adapter profiles (`adapters.json`) types and loading, effort mapping.
- [x] `arya-exec-adapter`: `text` and `jsonl` output parsers, prompt via stdin or argument,
  workdir, result schema validation; tested with a shell script standing in for an agent.

M4:
- [x] Example profiles for the print modes of common command-line agents; MCP config written
  into `workdir` from `run/start.tools`; `sandbox` capability reported honestly.
- [x] Bounded reads: cap a stdout line (default 8 MiB) and the exec adapter's kept output, so
  a runaway adapter or agent cannot exhaust memory; an over-long line is a protocol error.
- [x] Real cost for exec profiles: a `jsonl` line `{"cost":{"inputTokens":…,…}}` sets the
  `run/cost` answer, and the profile then reports `cost: true`.
- [x] Run the conformance suite against the exec adapter (a shell agent) as well as the fake
  one, and add a `just conformance` recipe for `ARYA_ADAPTER_CMD`.
- [x] Clean up exec temp state: delete `.arya-mcp.json` after the run; tests remove their
  temp directories.
- [x] `ReplayAdapter(ledgerPayloads:exit:)` for eval's `arya replay` (pointer in eval's
  Questions).
- [x] `parse: "stream-json"` for Claude Code (live events, real cost); the `claude-code`
  example uses it.
- [x] `parse: "codex-json"` for Codex CLI `exec --json` (live events, token counts); the
  `codex-cli` example uses it.
- [x] Outcome fields on `run/result`: `plan`, action `risk`, `why` on decisions and actions;
  in the result schema and the triage example.
- [x] OS sandbox: `run/start.sandbox` (SBPL profile + params), capability `sandbox: "os"`, the
  exec adapter launching under `sandbox-exec`, and `OSSandbox` helpers for the runtime.
- [x] In-run crews: `host/delegate` (`HostDelegateParams` → `HostDelegateResult`), the
  `.delegate` update and `answerDelegation`, the fake `delegate` step, and the triage example
  handing "Draft the refund reply" for MSG-203 to a child run. The runtime wires real fan-out
  (pointer in runtime's Questions); until then `RunDriver` and `Judge` answer `refused`.
- [x] History import convention: binding tool `history` (past records with what a person did,
  paged oldest first), `BindingHistory.page`, the fake MCP binding
  (`arya-fake-adapter --binding`), and `etc/examples/triage/inbox-history.json` (40 messages).
- [x] Connection testing: protocol `ping`, `ConnectionProbe.adapter` / `.binding` reports with
  a one-sentence `problem`, and a conformance check, for the connect lane's "test connection".
- [x] Binding conventions `outcome` (follow-up checks), `directory` and `process` (onboarding),
  served by the fake binding with triage data; shared `BindingServer` core.
- [x] Local connectors in `arya-binding`: `folder` (JSON, JSONL, CSV exports) and `http-json`
  (https only, no redirects, token from `ARYA_CREDENTIAL`), tested without network.
- [x] Work events (M3.5 points 1 and 4): `tool_output` chunks (runtime's 0049 kind, plus
  `stream`), `diff`, and `progress` with typed views; fake script `stream` and `pauseMs` steps
  that wait only at runtime's demo pace (`ARYA_FAKE_PACE_MS`, 0051; 0 in tests); the
  triage refund, routine-write, and routine-revise runs show search hits, the order, streamed
  shell output, and the routine edit as a diff.
- [x] Work content across examples: MSG-202 order lookup, the crew child's drafted reply as a
  diff, the refunds check's confirmation spot-check, and each weekly digest's per-queue table
  streamed as command output; a test ties every output and diff to an answered call.
- [x] codex-json: commands and tool calls show as running from `item.started`.
- [x] Live output from real harnesses: `stream-json` partial messages stream the reply as a
  `compose` step; `parse: "command"` and the `shell` example profile run a routine or check
  as one `shell` call whose stdout and stderr stream live; an opt-in live test
  (`ARYA_LIVE_HARNESS=<profile>`, never in CI) and a transcript fixture in the documented
  format.
- [ ] Next: replace `stream-json-partial.jsonl` with a recorded transcript the first time
  someone runs the live test with a signed-in agent CLI.
- [x] Eval's history import reads binding `history` as `HistoryItem` (`HistoryImport`).

## Handoff (2026-11-10)

The lane's backlog is done; the session is retiring. State for whoever picks it up:

- Protocol: `docs/PROTOCOL.md` matches the code (`Sources/AryaAdapters/Protocol`). Work
  events are `tool_output` (runtime 0049, plus optional `stream`), `diff`, and `progress`,
  read through `RunEvent.outputChunk`, `fileDiff`, and `progress`; they decode as `.other`,
  so they are not `Body` cases. Binding conventions: `history`, `outcome`, `directory`,
  `process` (`Protocol/History.swift`, `Protocol/BindingConventions.swift`).
- Adapters: fake (`Fake/`, scripts with `stream` and `pauseMs` steps, runtime's demo pace
  `ARYA_FAKE_PACE_MS`), replay (`Replay/`), exec (`Exec/`; parse modes `text`, `jsonl`,
  `stream-json` with partial messages as `compose` steps, `codex-json` with calls shown at
  `item.started`, and `command` for live shell output). Example profiles: `claude-code`,
  `codex-cli`, `shell` (`Profiles/ExampleProfiles.swift`, mirrored in
  `etc/examples/adapters/adapters.json`, which `AryaCLITests` checks).
- Bindings: `arya-binding folder` and `http-json` (`Bindings/`), secrets only through
  `ARYA_CREDENTIAL`; the fake binding serves the triage data in
  `etc/examples/triage/inbox-history.json`.
- Tests: `just test AryaAdaptersTests` (deterministic, no network, no waits at pace 0).
  `ARYA_LIVE_HARNESS=<profile>` runs one real run end to end; it is opt-in and never in CI.
- Open: the one unchecked backlog item (record a real `stream-json` transcript with a
  signed-in agent CLI to replace the hand-written fixture). Questions from other lanes above
  are answered in the log and Decisions; none waits on this lane.
- Watch: example script results feed policy, e2e, casebook, and replay tests in other
  targets; changing a response's `result` (not its events) moves their expectations. Replay
  compares derived events, so any new clock-derived payload field needs an entry in eval's
  `Canonicalizer.durations`.

## Decisions

- Free-form JSON uses `AryaCore.JSONValue`; the wire encoding is `CanonicalJSON`, so recorded
  lines are byte-stable.
- `RunResultParams.result` stays a raw `JSONValue` so the runtime can validate it against
  `resultSchema` and record it even when it does not decode; `decodedResult()` gives the typed
  `RunResult`, whose absent lists decode as empty.
- Unknown `run/event` kinds decode as `.other(kind:fields:)` and re-encode unchanged.
- `effort` is a plain string on the wire types; the runtime maps it from `AryaCore`'s charter
  type, which avoids a second `Effort` type.
- One client, `AdapterConnection`, serves every transport. `FakeAdapter` is that client over an
  in-memory pipe to `FakeAdapterServer`, the same server the `arya-fake-adapter` binary runs, so
  host code paths are identical in tests and with real processes.
- `AdapterUpdate.wire` carries every line in both directions, in order, before the typed update
  it produces; the runtime records `.wire` as `run.adapter.event`.
- stderr goes to a `StderrSink`; the runtime passes one that writes the transcript blob.
  `StderrBuffer` keeps it in memory.
- The stop grace (10 s, then SIGTERM, then SIGKILL after 5 s) applies to every `run/stop`,
  not only timeouts, so a person's stop cannot hang a run.
- `AdapterCommand.environment` is the child's complete environment, passed by the caller;
  names without `/` are resolved on its `PATH` through `/usr/bin/env`.
- Fake adapter scripts use the cli-e2e format (`responses` keyed by input text, `default`) as
  decided by the project lead; failure and timing controls (`steps`, `cost`, `startError`,
  `ignoreStop`) are optional additions to a response. The list form `runs`, which the triage
  example adopted before the decision, is read as an equivalent so neither lane has to churn.
- The idle timer pauses while any `host/ask` is unanswered (runtime's proposal), so a slow
  answer expires the question, not the run.
- `WireRecord.source` says who wrote a line: `host` (a runtime call), `connection` (the
  idle-timeout `run/stop`, replies to unserved requests), or `adapter`. `ReplayAdapter`
  replays `connection` lines itself, so replay needs no runtime timer. `ledgerPayload` and
  `init?(ledgerPayload:)` map records to and from `run.adapter.event` payloads, writing
  `source` only for `connection`.
- `ReplayAdapter` checks each host line against the recording by decoded message (method,
  id, params), so ids must match: the runtime makes the same calls in the same order.
- `AdapterProfiles` derives `kind` (`exec` when an exec-only field is present) so the PROTOCOL
  example and the triage example both load unchanged; a missing effort falls back to
  `medium`, which lets one-argument-list profiles work at every effort.
- An exec profile launches `arya-exec-adapter --profile <name> --profiles <file>` and the exec
  adapter maps effort from `run/start`, so the host needs no exec-specific logic.
- The exec adapter checks results with `ResultSchema`, a small JSON Schema subset (`type`,
  `properties`, `required`, `additionalProperties: false`, `items`, `enum`, `const`,
  `minItems`, `maxItems`); other keywords are ignored. It is public so the runtime's
  `invalid_result` check gives the same answer.
- `text` output becomes one `message` event at exit rather than an event per line, so
  transcripts do not fill with partial lines.
- `ProcessTransport.write` queues the line on a serial stdin queue and returns, so a peer that
  stops reading cannot block the connection actor or its request timeouts; a failed write is
  not thrown because `.ended` reports the dead peer.
- Tests use generous timeouts (`Sample.timeouts`: request 30 s, stop grace 10 s, kill 5 s,
  exit 10 s) and wait on signals (a `ready` line, the result) rather than sleeps; only tests
  about escalation shorten the one grace they exercise, and they assert the outcome, not time.
  `ProcessTransport` waits 5 s (was 1 s) after exit for end-of-file so a slow reader drains.
- `plan` step `status` and action `risk` are strict enums: an unknown value makes the result
  undecodable, so the run fails with `invalid_result` rather than showing a guess. An empty
  plan is not encoded, so results without one stay byte-identical.
- The OS sandbox is chosen by arya and only executed by adapters: arya sends the profile text so
  policy stays in one place. The standard profile allows writes only in `WORKDIR`, `/dev` nodes,
  and listed paths; temp directories are not writable (workdirs live there), so the exec adapter
  points `TMPDIR` into the workdir. An adapter that cannot sandbox rejects the run with `-32002`.
- Sandbox denials are reported, not fatal: the exec adapter watches the agent's stderr for
  `Operation not permitted` and emits one `error` sentence with the first denied line; the run's
  status still follows the agent, so a harness probing a cache directory does not lose a valid
  result. macOS logs violations elsewhere, so stderr is the signal an adapter can see.
- The idle timer sleeps on an injectable `SleepClock` (`AdapterConnection(idleClock:)`, also on
  `FakeAdapter`); tests step it with a manual clock, so idle behavior never depends on load.
- `host/delegate` mirrors `run/result.delegations` (string `input`, parent's charter and input
  kind, depth 1, child actions proposed only) and answers when the child ends. No capability
  flag: a host without it answers `-32601`, and `refused` covers depth and rehearsal limits, so
  an adapter always has the result-delegation fallback. The idle timer pauses while one is open.
- `history` is a binding tool, not an adapter method: past records live in the systems
  bindings reach, and the importer reaches them the same way runs do. Items carry the person's
  actions in proposed-action terms plus `choice` and `outcome`, so a case's expectation and a
  correction (`reopened`) need no binding-specific parsing.
- `ping` is optional for adapters: `-32601` also proves the process is alive. Probes never
  throw; their `problem` sentence ends with the command's last stderr line, which is usually
  the actionable part (a missing key or flag).
- Work events are ordinary `run/event` kinds read through `RunEvent` views, not new `Body`
  cases: every host and exhaustive switch keeps compiling, and older hosts keep them as
  unknown kinds. Scripted pauses follow runtime's demo pace (0051), so tests,
  seeding, and replay never wait.
- Example profile ids are the names of the public command-line tools they drive
  (`claude-code`, `codex-cli`, `shell`), because a person picks a harness by the tool they
  have. Docs describe them in neutral, factual terms: what command runs and with which
  flags, no comparisons (CEO decision, 2026-11-10; closes the profile-name question).
- Partial reply text streams as a `compose` step: runtime records output only under an open
  tool call, so the reply as it is written gets a call of its own, and the complete
  `message` still follows for the conversation.
- `parse: "command"` treats the input as the command and adds no instructions; it reports no
  cost, and a nonzero exit fails the run.
- `ProcessTransport` ignores SIGPIPE process-wide so a write to an exited adapter fails with
  an error instead of killing arya.

## Questions

- (from eval) Could `ReplayAdapter` publish `.exited` after `replayDivergence`? (now wrapped)
- (from runtime) Decision 0043: I added optional `adapter`, `effort`, `limits` to `RunResult.Delegation` and a PROTOCOL.md sentence (fake adapter passes them through already). Please keep or reshape; if you prefer a mid-run `host/delegate` request later, the runtime side can reuse `CrewBudget`.
- (from runtime) Decision 0046: added `RunInputKind.replan` and a PROTOCOL.md note; adapters treat it like any input text.
- (from runtime) Decision 0049: runs record live steps; added an optional `tool_output` event (`id`, `text`) to PROTOCOL.md. Could the exec adapter stream a command's output as `tool_output` while it runs, and the fake adapter send it with `sleep` steps between, so runs show live output?
- (from runtime) Integration edit (decision 0051): `FakeAdapterServer(pace:)` / `FakeAdapter(pace:)` and `ARYA_FAKE_PACE_MS` in `arya-fake-adapter`: events wait about `pace` ms and string tool results stream as `tool_output` first; 0 keeps scripts exact.
- (from runtime) In-run `host/delegate` is wired (decision 0053): a real child through the crew path; refusals are `depth_limit`, `adapter_not_allowed:<name>`, `unknown_effort:<v>`.
- (from runtime) Integration edits: `RunResult.findings` (`RunResult.Finding`, encoded only when non-empty) and its PROTOCOL bullet (decision 0055).

## Log
- 2026-11-09: protocol types, JSON-RPC messages, golden tests (dc550be)
- 2026-11-09: `Adapter`, `AdapterConnection`, `ProcessTransport`, `FakeAdapter`,
  `arya-fake-adapter`, conformance suite (bd040dc). Runtime: construct `FakeAdapter(script:)`
  or `AdapterConnection.launch(_:)` and record every `.wire` update.
- 2026-11-09: adopted the shared fake script format (`responses`/`default`, list form `runs`
  still read; `FakeScript(runs:)` kept for the runtime tests) (43bc3e6); stderr drains before
  exit is reported (e9c7c72).
- 2026-11-09: idle timer pauses during `host/ask` (cb9c713); in-memory SIGTERM race fixed
  (237de0a).
- 2026-11-09: `ReplayAdapter`, `WireRecord.source`, ledger payload mapping (c9c43a8).
- 2026-11-09: adapter profiles (b1cb086); `arya-exec-adapter` with `text`/`jsonl` parsing,
  prompt delivery, MCP config, and `ResultSchema` checks (cd8bf50). Runtime may reuse
  `ResultSchema.violation(of:by:)` for `invalid_result`.
- 2026-11-09: example profiles (07db438), bounded reads and exec cleanup (5f18ae2), jsonl cost
  (52bdc83), conformance over fake and exec plus `just conformance` (3d88e82),
  `ReplayAdapter(ledgerPayloads:exit:)` (21f7c6c), `stream-json` parsing (cd5b17e).
- 2026-11-09: `codex-json` parsing (dd2bf06), exec prompt off the server loop (604802b),
  queued stdin writes (65c2170). Hardened timing-sensitive tests for machine load;
  AryaAdaptersTests passed 5 of 5 runs under load average ~230.
- 2026-11-09: plan/risk/why (63e1030); test hardening (fb94eff); shipping and high-risk refund
  triage messages, billing binding, fallback-never-a-message test (2292097).
- 2026-11-09: OS sandbox for exec agents (a708516); idleTimerPausesWhileAQuestionIsOpen now
  runs on a manual clock (a mutation that drops the pause fails it in 10 s instead of hanging).
- 2026-11-09: idle-timer test on a manual clock (41dc71a); `host/delegate` for in-run crews,
  the fake `delegate` step, and the triage refund-reply delegation.
- 2026-11-09: binding `history` convention, fake MCP binding, triage inbox history (40 items).
- 2026-11-09: `ping` and `ConnectionProbe` (adapter and binding test connection).
- 2026-11-10: `outcome`, `directory`, `process` conventions; `arya-binding` folder and
  http-json connectors (connect already uses `ConnectionProbe`; the name stays).
- 2026-11-10: Paused for the night after the connectors commit. Next: the open backlog item
  above (eval history import check), then the product-name question.
- 2026-11-10: work events (`tool_output` stream, `diff`, `progress`), paced fake `stream` and `pauseMs`
  steps, and realistic triage work in MSG-201, MSG-134, and MSG-137.
- 2026-11-10: Visual check (`just snapshot`, demo home, run-approval): the MSG-201 run stream
  now fills with real work (the fetched message, three search hits, the order with two
  captured charges, the reasoning) before the approval; moves points 2 (density from real
  content) and 5 (busy demo). Progress, output, and diffs await app-views rendering (point 1).
- 2026-11-10: work content in MSG-202, the MSG-203 draft child, refunds, and digest scripts.
  Held the publish per the CEO's CI-queue order; batching locally.
- 2026-11-10: codex-json `tool_call` at `item.started` (live running state).
- 2026-11-10: replay ignores step `millis` (eval integration edit); MSG-201's tool calls exposed it.
- 2026-11-10: Visual check (`just snapshot` after fb983d8): the split work pane shows Tools,
  Diff, Log, and Output counts; run-approval (now the MSG-140 hand-off) fills both panes. The
  Diff tab draws actions and routine versions, not adapter `diff` events yet (asked in
  app-views' Questions). Moves points 1 and 4 through `tool_output` steps in paced runs.
- 2026-11-10: profile-name question closed (CEO: keep tool-named ids, neutral docs).
  Partial-message `compose` steps, `command` parse mode and `shell` profile with live stdout
  and stderr, opt-in live harness test; eval's `HistoryItem` adoption confirmed.
- 2026-11-10: handoff written; backlog done (one optional fixture refresh left).
