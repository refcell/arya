# Lane: adapters

Owns `Sources/AryaAdapters`, `Sources/AryaFakeAdapter`, `Sources/AryaExecAdapter`,
`Tests/AryaAdaptersTests`, and `docs/PROTOCOL.md`.

Goal: **any harness, one contract.** A typed client for the adapter protocol, a robust process
transport, a deterministic fake adapter every test uses, a replay adapter for `arya replay`, and
a reference adapter that wraps command-line agents. Design: [PROTOCOL.md](../PROTOCOL.md),
decisions 0004, 0014, 0016.

## Backlog

M1:
- [ ] Protocol types: requests, responses, notifications, `RunEvent`, `RunResult`,
  capabilities, error codes; golden tests for every example in PROTOCOL.md.
- [ ] Line-delimited JSON-RPC codec: framing, id matching, notifications, adapter-to-host
  requests, protocol errors on non-JSON stdout.
- [ ] `Adapter` protocol (async): `initialize`, `start`, `send`, `stop`, `cost`, `shutdown`, an
  `AsyncStream` of messages; every message in both directions surfaced for recording.
- [ ] Process transport: spawn with `Foundation.Process`, pipes, stderr capture to a blob
  writer, timeout handling (`run/stop`, then SIGTERM, then SIGKILL), exit detection
  (`adapter_exited`).
- [ ] `FakeAdapter` (in-process) driven by a script: events and a result keyed by input text;
  can simulate delays, errors, crashes, and `host/ask`.
- [ ] `arya-fake-adapter --script <file>`: the same script over stdio; script format documented
  in PROTOCOL.md.
- [ ] Conformance suite (`AdapterConformance`) run against `arya-fake-adapter` by default and
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

## Questions

## Log
