# Examples

Example stewards with everything needed to rehearse and run them offline. `just e2e` and
`just demo` use them, and the CLI tests check that each example is internally consistent.
Everything here is invented: no real people, customers, or systems.

## templates: example stewards to start from

`templates/<id>.json` are charters for five example stewards: support triage, lead follow-up,
vendor spend review, product adoption, and customer commitments. The app and
`createFromTemplate` start from them; a test keeps the files equal to the facade's catalog.

## triage: support inbox triage

A steward that labels each new message in a fictional support inbox and routes it to the queue
that owns it. It may label and route on its own, must ask before replying to a customer, and may
never delete a message.

| File | What it is |
| --- | --- |
| `charter.json` | the charter, in the shape from [ARCHITECTURE.md](../../docs/ARCHITECTURE.md#charters-and-cases) |
| `casebook.jsonl` | eight past messages with their known category and actions |
| `fake-script.json` | what the fake adapter answers for each input (see below) |
| `adapters.json` | the fake adapter profiles for every example; paths are relative to the repository root |
| `charter-v2.json` | a proposed version 2 that `just demo` proposes; its `fake-triage-v2` profile runs `fake-script-v2.json` |
| `judge/` | a rubric judge for tone and policy adherence with recorded verdicts ([judge/README.md](triage/judge/README.md)) |

The scripted steward gets seven of the eight cases right. On `case-0006` ("Update card on
file") it answers `billing` where the casebook says `how-to`; the message is about the card the
customer is charged with, so the correction in the end-to-end scenario sets the expected choice
to `billing`, and the next rehearsal scores eight of eight.

The live input `New message MSG-201: Refund for a duplicate charge` produces a `label` and a
`route` action, which the policy executes, and a `reply`, which waits for approval. It also
records one memory note and one `routed_within_1h` measurement.

`New message MSG-203: Damaged order, please refund` hands "Draft the refund reply" to a crew:
its result's `delegations` start a child run that drafts the reply (children only propose), and
the script's `joins` entry answers the join run, which checks the draft.

`charter-v2.json` drops the security routing guardrail and treats card-on-file questions as
how-to. Gated on the casebook as imported, it improves `case-0006` and regresses `case-0005`
(seven of eight both ways), so the gate fails and the demo home has one failed proposal to show.

## refunds and digest: a small fleet

Two more stewards, so `just demo` seeds a fleet in different states. Each has a `charter.json`, a
`casebook.jsonl`, a `fake-script.json` (profiles `fake-refunds` and `fake-digest` in
`triage/adapters.json`), and a `history.txt` of `DAYS-AGO<tab>input` lines.

- `refunds` (Refund follow-up) confirms each approved refund reached the customer within a
  business day. It may add internal notes on its own and must ask before replying. Its metric
  climbs from 0.70 to 0.86, short of the 0.90 target, and the newest unannounced refund
  (ORDER-1043, the one from triage's MSG-203) leaves a reply waiting for approval.
- `digest` (Weekly queue digest) posts a weekly summary of queue health to the team. It runs for
  four weeks, misses its on-time target twice, and the demo pauses it two days before today.

## Fake adapter script

`fake-script.json` uses the script format of `arya-fake-adapter --script <file>`
([PROTOCOL.md](../../docs/PROTOCOL.md#fake-adapter-scripts)): `responses` maps each case input
and the live input to `run/event` payloads and a `run/result`, and `default` answers anything
else.

`triage/history.txt` lists invented past messages that `just demo` runs in order, one a day
over the past month (`ARYA_CLOCK` stamps each command with its past time), so the demo
home shows a steward with weeks of decisions, a memory, and a routine proposal. Every scripted
run returns its `plan`, a `why` for each decision and action, and each action's `risk`. [adapters/](adapters) holds exec profiles for public command-line agents.


`triage/inbox-history.json` is the inbox binding's past: 40 invented messages, each with the label
and queue a person chose and how it turned out, served by `arya-fake-adapter --binding` through the
`history` tool ([PROTOCOL.md](../../docs/PROTOCOL.md#binding-conventions)). eval's casebook importer
reads it.