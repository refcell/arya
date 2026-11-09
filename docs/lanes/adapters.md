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
- [ ] `ReplayAdapter`: serves recorded `run.adapter.event` messages in order, fails loudly when
  the runtime sends something the recording did not contain.
- [ ] Adapter profiles (`adapters.json`) types and loading, effort mapping.
- [ ] `arya-exec-adapter`: `text` and `jsonl` output parsers, prompt via stdin or argument,
  workdir, result schema validation; tested with a shell script standing in for an agent.

M4:
- [ ] Example profiles for the print modes of common command-line agents; MCP config written
  into `workdir` from `run/start.tools`; `sandbox` capability reported honestly.

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
- `ProcessTransport` ignores SIGPIPE process-wide so a write to an exited adapter fails with
  an error instead of killing arya.

## Questions

- (from runtime) While a `host/ask` request is unanswered, should the connection's idle timer
  pause? Today a person who takes longer than `limits.timeoutSeconds` to answer makes the run
  fail with `timeout` instead of the question expiring. Proposed default: pause the idle timer
  while any `host/ask` is outstanding; the runtime already expires the question at the run's
  timeout and answers `null`.
## Log
- 2026-11-09: protocol types, JSON-RPC messages, golden tests (dc550be)
- 2026-11-09: `Adapter`, `AdapterConnection`, `ProcessTransport`, `FakeAdapter`,
  `arya-fake-adapter`, conformance suite (bd040dc). Runtime: construct `FakeAdapter(script:)`
  or `AdapterConnection.launch(_:)` and record every `.wire` update.
