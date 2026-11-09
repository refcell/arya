# Examples

Example stewards with everything needed to rehearse and run them offline. `just e2e` and
`just demo` use them, and the CLI tests check that each example is internally consistent.
Everything here is invented: no real people, customers, or systems.

## triage: support inbox triage

A steward that labels each new message in a fictional support inbox and routes it to the queue
that owns it. It may label and route on its own, must ask before replying to a customer, and may
never delete a message.

| File | What it is |
| --- | --- |
| `charter.json` | the charter, in the shape from [ARCHITECTURE.md](../../docs/ARCHITECTURE.md#charters-and-cases) |
| `casebook.jsonl` | eight past messages with their known category and actions |
| `fake-script.json` | what the fake adapter answers for each input (see below) |
| `adapters.json` | the `fake-triage` adapter profile; paths are relative to the repository root |

The scripted steward gets seven of the eight cases right. On `case-0006` ("Update card on
file") it answers `billing` where the casebook says `how-to`; the message is about the card the
customer is charged with, so the correction in the end-to-end scenario sets the expected choice
to `billing`, and the next rehearsal scores eight of eight.

The live input `New message MSG-201: Refund for a duplicate charge` produces a `label` and a
`route` action, which the policy executes, and a `reply`, which waits for approval. It also
records one memory note and one `routed_within_1h` measurement.

## Fake adapter script

`fake-script.json` uses the script format of `arya-fake-adapter --script <file>`
([PROTOCOL.md](../../docs/PROTOCOL.md#fake-adapter-scripts)): `responses` maps each case input
and the live input to `run/event` payloads and a `run/result`, and `default` answers anything
else.

`triage/history.txt` lists invented past messages that `just demo` runs in order, one a day
over the past month (`ARYA_CLOCK` stamps each command with its past time), so the demo
home shows a steward with weeks of decisions, a memory, and a routine proposal. Every scripted
run returns its `plan`, a `why` for each decision and action, and each action's `risk`. [adapters/](adapters) holds exec profiles for public command-line agents.
