# Adapter protocol

An adapter is a process that runs an agent harness on arya's behalf. arya starts it, talks to it
over stdin and stdout, and records everything it says. Any language can implement an adapter.
How arya uses the results is described in [ARCHITECTURE.md](ARCHITECTURE.md#runs).

Version: `1`. A change that breaks an existing adapter bumps the version and gets an entry in
[DECISIONS.md](DECISIONS.md). Adding optional fields does not.

## Transport

- JSON-RPC 2.0, one JSON object per line (UTF-8, `\n`-terminated) on stdin (arya → adapter) and
  stdout (adapter → arya). stderr is free-form logging, captured into the run's transcript blob.
  Anything on stdout that is not a JSON-RPC message is a protocol error.
- arya sends requests; the adapter answers each with a response carrying the same `id`. The
  adapter sends notifications (no `id`) to stream events, and may send requests to arya (see
  `host/*`).
- One adapter process serves one run. arya starts a fresh process per run, which keeps crashes
  isolated and replay simple. A second `run/start` on the same process returns `-32005`.
- arya records every message in both directions as `run.adapter.event` ledger events, in the
  order it read or wrote them.

## Lifecycle

```
arya                                adapter
 │── initialize ──────────────────▶ │
 │◀──────────── capabilities ────── │
 │── run/start ───────────────────▶ │
 │◀──────────── {session} ───────── │
 │◀── run/event (notification) ×N ─ │
 │── run/send (optional) ─────────▶ │
 │◀── host/ask (optional) ───────── │
 │◀── host/delegate (optional) ──── │
 │◀── run/result (notification) ─── │
 │── run/cost ────────────────────▶ │
 │── shutdown ────────────────────▶ │  exits 0
```

If the adapter exits before `run/result`, the run fails with reason `adapter_exited`. If no
message arrives for `limits.timeoutSeconds`, arya sends `run/stop` with reason `timeout`, waits
10 seconds, then terminates the process (SIGTERM, then SIGKILL after 5 more seconds).

## Methods (arya → adapter)

### `initialize`

```json
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocol":1,"client":{"name":"arya","version":"0.1.0"}}}
```

Result:

```json
{"protocol":1,"adapter":{"name":"exec","version":"0.1.0"},
 "capabilities":{"effort":["low","medium","high"],"send":true,"cost":true,"transcript":true,
                 "tools":"mcp","sandbox":"workdir"}}
```

| capability | meaning |
| --- | --- |
| `effort` | effort levels the adapter maps to a model |
| `send` | supports `run/send` |
| `cost` | `run/cost` returns real numbers (otherwise zeros) |
| `transcript` | supports `run/transcript` |
| `tools` | `"mcp"` if the harness can use the MCP servers in `run/start.tools`, else `"none"` |
| `sandbox` | `"os"` if the adapter launches the harness under the OS sandbox in `run/start.sandbox`, `"workdir"` if the harness's built-in write tools are confined to `workdir` or off, `"none"` if they cannot be restricted |

If `protocol` is unsupported the adapter returns error `-32001`.

### `run/start`

```json
{"jsonrpc":"2.0","id":2,"method":"run/start","params":{
  "run":"run_01J…",
  "instructions":"…composed charter, guardrails, memory, routines…",
  "input":{"kind":"case","text":"…","attachments":[]},
  "effort":"medium",
  "workdir":"…",
  "tools":[{"name":"tracker","transport":"stdio","command":"arya",
            "args":["binding-proxy","--run","run_01J…","--binding","tracker"]}],
  "limits":{"maxTurns":40,"timeoutSeconds":900,"maxCostMicros":2000000},
  "resultSchema":{"…":"JSON Schema of run/result.result"},
  "sandbox":{"profile":"(version 1) …","params":{"WORKDIR":"…"}}}}
```

Result: `{"session":"<adapter session id>"}`. The adapter then works asynchronously.

- `input.kind` is `manual`, `schedule`, `message`, `case`, `join`, or `replan` (a
  setback: the attachments list the actions that did not happen).
- `tools` are MCP servers to hand to the harness. They are arya's binding proxies, not the real
  systems: they expose only read tools and record every call. Adapters pass them through
  unchanged and must not add other tools that reach external systems.
- `workdir` is a fresh scratch directory owned by the run. The adapter runs the harness there.
- `sandbox` (optional) is an OS sandbox arya chose for the harness: a macOS sandbox profile
  (SBPL text) and the parameters it reads with `(param "NAME")`. An adapter with capability
  `sandbox: "os"` launches the harness as `sandbox-exec -p <profile> -D NAME=value … <command>`;
  any other adapter rejects such a `run/start` with `-32002`, so a sandboxed run never runs
  unconfined. `OSSandbox.confiningWrites(to:extraWritablePaths:network:)` builds the standard
  one: writes only in `WORKDIR` (resolved, `/private/var/…`), the standard `/dev` nodes, and the
  listed paths (for a harness's own state directory), with outbound network allowed or denied.

### `run/send`

`{"session":"…","message":{"role":"human","author":"person:alex","text":"…"}}` → `{}`.
Delivers a person's message or correction mid-run. Adapters without `send` return `-32002`.

### `run/stop`

`{"session":"…","reason":"user"|"timeout"|"budget"}` → `{}`. The adapter must emit a final
`run/result` with `status: "stopped"` within 10 seconds.

### `run/transcript`

`{"session":"…"}` → `{"events":[RunEvent…]}`: the full event list, used to fill gaps if arya
missed notifications. Adapters without `transcript` return `-32002`.

### `run/cost`

`{"session":"…"}` → `{"inputTokens":0,"outputTokens":0,"costMicros":0}` (micro-dollars).

### `shutdown`

`{}` → `{}`, then the adapter exits with status 0.

### `ping`

`{}` → `{}`. Answered at any time after `initialize`, with or without a run, so arya can check that
an adapter is alive (the "test connection" step uses it). An adapter from before `ping` answers
`-32601`; arya counts that as alive too.

## Notifications (adapter → arya)

### `run/event`

```json
{"jsonrpc":"2.0","method":"run/event","params":{"session":"…","seq":7,
 "event":{"kind":"tool_call","at":"…","id":"t3","tool":"tracker.search","input":{…}}}}
```

`seq` starts at 1 and increments by 1 per session; a gap means arya missed events and may call
`run/transcript`. `event.kind` is one of:

| kind | fields | meaning |
| --- | --- | --- |
| `message` | `role`, `text` | assistant or user text |
| `thinking` | `text` | optional reasoning summary |
| `tool_call` | `id`, `tool`, `input` | the agent called a tool |
| `tool_result` | `id`, `output`, `isError` | the tool answered |
| `status` | `state`, `detail` | progress (`working`, `waiting`, …) |
| `error` | `message` | a recoverable error |

Events are informational: they feed the run stream and the transcript. Only `run/result` carries
decisions and actions. `at` is informational too; arya stamps its own time from `Ambient`.

### `run/result`

Sent exactly once per run:

```json
{"jsonrpc":"2.0","method":"run/result","params":{"session":"…","status":"completed",
 "result":{
   "summary":"…",
   "plan":[{"id":"p1","text":"…","status":"done","rationale":"…"}],
   "decisions":[{"id":"d1","choice":"…","rationale":"…","why":"…"}],
   "actions":[{"id":"a1","kind":"comment","binding":"tracker","target":"tracker:ISSUE-1",
               "params":{…},"rationale":"…","risk":"low","why":"…"}],
   "delegations":[{"id":"c1","title":"…","input":"…"}],
   "memories":[{"text":"…","tags":["…"]}],
   "routines":[{"name":"…","language":"sh","content":"…","reason":"…"}],
   "measurements":[{"metric":"…","value":1.0}]}}}
```

- `status` is `completed`, `failed`, or `stopped`. Every list may be empty or absent.
- Unknown fields are ignored. A `result` that does not match `resultSchema` fails the run with
  reason `invalid_result`; the raw message is still recorded.
- Actions are never executed by the adapter: arya applies the charter's policy and executes or
  holds them. `binding` names the charter binding that would carry out the action; action kind
  `routine` uses `params.name` instead.
- `delegations` become child runs after this run finishes, followed by one join run
  ([ARCHITECTURE.md](ARCHITECTURE.md#crews)).
  A delegation may add `adapter` (a profile the charter's `crew.adapters` lists), `effort`, and
  `limits` (as in `run/start`); arya caps each at the parent run's (decision 0043). To use a
  child's result before finishing, send `host/delegate` instead.
- `plan` (optional) is the run's plan as it stood at the end, so a person can see what the run
  set out to do and how far it got. Each step has `id`, `text`, `status` (`pending`,
  `in_progress`, `done`, `skipped`, or `blocked`), and an optional `rationale`. An empty plan
  is omitted.
- `risk` (optional, on actions) is the adapter's hint: `low`, `medium`, or `high`. It informs
  the person reviewing the action; the charter's policy alone decides what executes or waits.
- `why` (optional, on decisions and actions) is one short line the app shows next to the item.
  `rationale` stays the longer reasoning.
- arya's `resultSchema` lists these fields with their allowed values and a description, so an
  exec adapter's prompt carries them; a `status` or `risk` outside the allowed values fails the
  run with `invalid_result`.

## Requests (adapter → arya)

### `host/ask`

`{"session":"…","question":"…","to":"person:alex"}` → `{"answer":"…"}`. The adapter asks a
person a question (`to` is optional; the default is the local user). While it is unanswered, arya's
idle timer is paused; the run's `limits.timeoutSeconds` stays the hard cap, at which arya answers
`null`. arya shows it in the approval queue until it is answered or the run's timeout passes
(`"answer": null`). In rehearsal and replay the answer comes from the recording; an unrecorded
question in rehearsal answers `null`.

### `host/delegate`

`{"session":"…","id":"c1","title":"Draft the refund reply","input":"…"}` →
`{"run":"run_…","status":"completed","result":{…}}`. The adapter hands part of its work to a
child run and waits for it, so the agent can use the child's result before it finishes (a crew
inside a run).

arya runs the child like a `run/result` delegation: the parent's charter and input kind, `input`
as the input text, `parent` set, and its actions recorded as proposed only. The optional
`adapter`, `effort`, and `limits` mean what they mean on a delegation and are capped the same way. The child's actions
never execute; the parent proposes whatever it keeps in its own `run/result`. The answer comes
when the child ends.

`status` is `completed`, `stopped`, `failed`, or `refused`. `result` is the child's
`run/result.result` when it completed, and `reason` explains `failed` and `refused`. arya
refuses (no child, no `run`) when the run is itself a child or join run (depth 1), and runs at
most `crew.maxParallel` children at once; more wait their turn. While a delegation is open the
idle timer is paused; the parent's `limits.timeoutSeconds` stays the hard cap. In replay the
answer comes from the recording.

A host that does not know `host/delegate` answers `-32601`; an adapter then lists the work in
`run/result.delegations` instead. An adapter must treat `refused` the same way or finish without
the child.

## Errors

| code | meaning |
| --- | --- |
| `-32700`, `-32600`..`-32603` | JSON-RPC standard errors |
| `-32001` | unsupported protocol version |
| `-32002` | capability not supported |
| `-32003` | unknown session |
| `-32004` | harness failure (message has detail) |
| `-32005` | busy: this process already has a run |

## Effort

arya sends `low`, `medium`, or `high`. Each adapter maps effort to a model and reasoning budget
in its profile (`adapters.json`), so charters never name models.

## Binding conventions

Bindings are MCP servers that arya reaches through its binding proxy (see
[ARCHITECTURE.md](ARCHITECTURE.md)). Most of their tools are their own; the tools below follow a
shared shape so arya can use any binding that serves them.

### `history`

A read tool that lists past records together with what a person did with each, so arya can learn
from decisions made before it arrived (eval imports them into a casebook). A binding that serves it
lists `history` among its tools; a charter exposes it to runs only if `bindings[].read` names it.

```json
{"since":"2026-09-01T00:00:00Z","until":"2026-10-01T00:00:00Z","cursor":"50","limit":50}
```

Every argument is optional. Times are RFC 3339 in UTC (`Z`), so they compare as text: `since` is
inclusive and `until` exclusive. `limit` is 1 to 500 (default 50). `cursor` is the `next` of the
previous page; it is opaque to the caller. The result, as the call's `structuredContent` (and as
JSON text in `content`), is one page, oldest first:

```json
{"items":[{"id":"MSG-004","at":"2026-09-03T11:00:00Z",
  "input":"New message MSG-004: Order has not shipped",
  "record":{"id":"MSG-004","subject":"Order has not shipped","body":"…"},
  "actions":[{"kind":"route","target":"inbox:MSG-004","params":{"queue":"help"},
              "by":"person:sam","at":"2026-09-03T11:42:00Z"},
             {"kind":"route","target":"inbox:MSG-004","params":{"queue":"shipping"},
              "by":"person:alex","at":"2026-09-03T14:00:00Z"}],
  "choice":"shipping",
  "outcome":{"status":"reopened","at":"2026-09-03T14:00:00Z","note":"Rerouted."}}],
 "next":"50"}
```

- `id` is the record's id, the one the binding's `get` tool takes; `at` is when it arrived.
- `input` is the run input arya would have received for the record.
- `record` (optional) is the record as `get` returns it, so an importer needs no extra calls.
- `actions` lists what people did, in order, in the terms of proposed actions (`kind`, `target`,
  `params`) plus `by` (a contact id) and `at`. It is empty when nobody acted.
- `choice` (optional) is the person's decision in one word, such as a category or queue.
- `outcome` (optional) says how it turned out: `status` is `resolved`, `reopened` (the first
  handling was not enough), or `open`; other words are kept as text. `note` explains.
- `next` is absent on the last page.

The types are `HistoryListParams`, `HistoryListResult`, and `HistoryItem` in `AryaAdapters`;
`BindingHistory.page` implements the paging for a list held in memory.

## Reference adapters

- `arya-fake-adapter --script <file>`: replays a JSON script of events and results keyed by
  input text. Deterministic; used by every test and by the demo.
- `arya-exec-adapter --profile <name>`: wraps a command-line agent. A profile names the command,
  arguments per effort, how the prompt is passed (stdin or argument), how MCP tools are passed (a
  config file in `workdir` or none), and how output is parsed: `text` (the last fenced `json` block
  is the result) or `jsonl` (one event per line, the last object with a `result` key is the result),
  `stream-json` (Claude Code's `--output-format stream-json`), or `codex-json` (Codex CLI's `exec
  --json`). Example profiles cover the non-interactive print modes of common command-line agents
  such as Claude Code and Codex CLI (`AdapterProfiles.examples`: `claude-code` runs `claude -p` with
  `stream-json` output, a model alias per effort, arya's tools through `--mcp-config`, and its
  shell, file-writing, and web tools disallowed; `codex-cli` runs `codex exec --json --sandbox
  read-only` with `model_reasoning_effort` per effort and no arya tools). Both report `sandbox:
  "workdir"` because neither can write outside or reach the network through built-in tools.

```json
{"v":1,"profiles":{"exec-default":{"command":"claude","promptVia":"stdin","parse":"text",
  "args":{"low":["-p"],"medium":["-p"],"high":["-p"]},"mcpConfig":"none"}}}
```

`adapters.json` profile fields (`AdapterProfiles` in `AryaAdapters`):

| field | meaning |
| --- | --- |
| `kind` | `adapter` (the command speaks this protocol) or `exec` (wrapped by `arya-exec-adapter`); when absent, `exec` if any exec field below is present, else `adapter` |
| `command` | a path, or a name looked up on `PATH` |
| `args` | arguments per effort (`low`, `medium`, `high`); a missing effort uses `medium`'s, then none |
| `env` | variables added to the environment arya passes |
| `promptVia` | exec: `stdin` (default) or `argument` (appended last) |
| `parse` | exec: `text` (default), `jsonl`, `stream-json`, or `codex-json` |
| `mcpConfig` | exec: `none` (default) or `file` (a config written into `workdir`; its path replaces `{mcpConfig}` in `args`) |
| `sandbox` | exec: `workdir` if these arguments confine or disable the agent's write tools, else `none` (default); reported as the `sandbox` capability |

An `adapter` profile runs `command` with `args[effort]`. An `exec` profile runs
`arya-exec-adapter --profile <name> --profiles <adapters.json>`, which maps effort itself from
`run/start.effort`. Unknown effort keys, an empty command, and `mcpConfig: "file"` without a
`{mcpConfig}` argument are rejected when the file is loaded.

### Exec adapter

`arya-exec-adapter --profile <name> --profiles <adapters.json>` serves one run by starting the
profile's agent in `workdir` with the profile's environment. The prompt is the instructions, then
`Input (<kind>):` and the input text, any attachments as JSON, and a closing paragraph that asks for
the result in the profile's output form, including `resultSchema` when given. With `mcpConfig:
"file"` it first writes `workdir/.arya-mcp.json` (`{"mcpServers":{"<name>":
{"command":…,"args":[…]}}}`, one entry per `run/start.tools` item). It sends a `status` event when
the agent starts; `jsonl` lines that are run events are forwarded as they arrive, and with `text`
the whole output becomes one `message` event at exit. A `jsonl` line
`{"cost":{"inputTokens":…,"outputTokens":…,"costMicros":…}}` (running totals; absent fields are
zero) sets the `run/cost` answer, so `jsonl` profiles report `cost: true`. With `stream-json`,
`assistant` and `user` message blocks become `message`, `thinking`, `tool_call`, and `tool_result`
events as they arrive; the final `result` line's text supplies the result (its last fenced json
block), its `total_cost_usd` and `usage` (input counts include cache reads and writes) answer
`run/cost`, and `is_error` fails the run. With `codex-json`, completed `reasoning`, `agent_message`,
`command_execution` (tool `shell`), and `mcp_tool_call` (tool `<server>/<tool>`) items become
`thinking`, `message`, and `tool_call` plus `tool_result` events; the last agent message supplies
the result; `turn.completed` usage adds up into `run/cost` tokens (Codex reports no dollar cost, so
`costMicros` stays 0); and `turn.failed` or `error` fails the run with its message. The run is
`completed` when the agent exits 0 with a result that matches `resultSchema`; otherwise it is
`failed` with an `error` event saying why (the result, if any, is still sent). `run/stop` terminates
the agent and the run ends `stopped`. Capabilities: `effort` lists the efforts in `args`, `send` is
false, `cost` is true for `jsonl` and `stream-json`, `tools` is `mcp` for `mcpConfig: "file"`, and
`sandbox` is `os` when `/usr/bin/sandbox-exec` exists, otherwise the profile's value. With
`run/start.sandbox` the agent is launched under it, with `TMPDIR` set to `workdir/.tmp` so temporary
files stay writable. When the sandboxed agent's stderr shows a denied operation (`Operation not
permitted`), the run reports one `error` event: "The sandbox blocked the agent from writing outside
its workdir or using the network (<first denied line>)." The run's status still follows the agent's
exit and result. The agent's stderr is forwarded to the adapter's stderr. Only the last 8 MiB of
output is kept for parsing, and `.arya-mcp.json` is deleted when the run ends.

### Fake adapter scripts

`arya-fake-adapter --script <file>` and the in-process `FakeAdapter` run the same server from a
JSON script. `responses` maps the exact `run/start.input.text` to a response; other inputs get
`default`; with neither, `run/start` fails with `-32004`. The session id is `fake-<run>`.
A `default` response should report itself with a `status` or `error` event, never a `message`, so
the app does not show the fallback as something the agent said.

```json
{"v":1,
 "responses":{
   "New message MSG-101: Charged twice":{
     "events":[{"kind":"status","state":"working","detail":"reading the message"},
               {"kind":"message","role":"assistant","text":"This looks like billing."}],
     "status":"completed",
     "result":{"summary":"Labeled MSG-101 as billing.","decisions":[{"id":"d1","choice":"billing"}],
               "actions":[],"measurements":[]}}},
 "default":{"events":[],"status":"completed","result":{"summary":"Nothing to do."}}}
```

`events` are `run/event` payloads without `seq` (the adapter numbers them; `at` is optional);
`status` (default `completed`) and `result` become the `run/result` notification. Everything
else is optional:

| field | meaning |
| --- | --- |
| `adapter` | `initialize` adapter info, default `{"name":"fake","version":"0.1.0"}` |
| `capabilities` | `initialize` capabilities, default all of `send`, `cost`, `transcript`, tools `none`, sandbox `workdir` |
| response `cost` | the `run/cost` result, default zeros |
| response `startError` | `{"code":…,"message":…}`: `run/start` fails with it |
| response `ignoreStop` | `true`: `run/stop` is acknowledged but no `run/result` follows |
| response `steps` | performed after `events`, in order, one key each (below) |
| `joins` | responses for crew join runs, by delegation id: a `join` input answers with the entry for the first child's `delegation` it names (its text carries run ids, so `responses` cannot match it) |

| step | effect |
| --- | --- |
| `event` | emit a `run/event` |
| `sleepMs` | wait that many milliseconds |
| `ask` | send `host/ask` (`question`, optional `to`), wait, then emit the answer as a `message` event with role `human` |
| `delegate` | send `host/delegate` (`id`, `title`, `input`), wait, then emit a `status` event with state `delegated` and detail `<status>[ <run>][: <reason>]` (an error answer reads as `refused`) |
| `stdout` | write the text as one raw stdout line (a protocol error) |
| `crash` | exit with `exitCode` without a `run/result` |
| `hang` | produce nothing until `run/stop` |

`run/send` emits the message as a `message` event, and `run/stop` ends the run with
`status: "stopped"`.

The list form `"runs":[{"input":"…", …response fields…}, …]` is equivalent: each run answers
its `input`, and the run without `input` is the default. When both forms name an input,
`responses` wins. `etc/examples/triage/fake-script.json` is a complete example in the list
form.

`arya-fake-adapter --binding <file>` serves a fake MCP binding instead: `history`, `get` (`{id}`,
the record), and `search` (`{query}`, `{items}` of records containing it) from
`{"v":1,"history":[…items…]}`. `etc/examples/triage/inbox-history.json` holds 40 past triage
messages with the routing a person chose; five were rerouted and are marked `reopened`.

## Host behavior

arya's client (`AdapterConnection` in `AryaAdapters`) enforces the timing rules above: a request
fails after 30 seconds without a response; after `run/stop`, sent by a person or by the idle
timeout, the adapter has 10 seconds to send `run/result` before SIGTERM and, 5 seconds later,
SIGKILL; after `shutdown` it has 5 seconds to exit. The idle timer pauses while a `host/ask` or
`host/delegate` request is unanswered; the runtime expires it at the run's timeout instead. A stdout
line that is not a JSON-RPC message is recorded as received and reported as a protocol error; the
runtime decides whether it fails the run. A request from the adapter other than `host/ask` and
`host/delegate` gets `-32601`. A stdout line over 8 MiB is cut at 8 MiB (the rest up to the next
newline is dropped), so it is recorded cut and fails as a protocol error.

## Replay

`ReplayAdapter` serves a recorded conversation for `arya replay`. Each call from the runtime
must write exactly the next recorded host line (same method, id, and params); the recorded
adapter lines up to the next host line are then published in order and the call returns its
recorded response. Lines the connection wrote on its own (the idle-timeout `run/stop`, replies to
unserved requests, marked `"source":"connection"` in `run.adapter.event`) replay without a call.
Any other line from the runtime fails with a divergence that shows both lines. Build one from a
run's `run.adapter.event` payloads in ledger order with `ReplayAdapter(ledgerPayloads:exit:)`.

## Conformance

The conformance suite in `Tests/AryaAdaptersTests` runs the protocol against any adapter
binary:

```sh
ARYA_ADAPTER_CMD="path/to/adapter args" just test AdapterConformance
```

It checks the handshake, version negotiation, `ping`, one-run-per-process, `seq` ordering, exactly one
`run/result`, `run/stop` within 10 seconds, error codes, and clean exit on `shutdown`. Without
`ARYA_ADAPTER_CMD` it runs against `arya-fake-adapter`.

## Connection testing

`ConnectionProbe` in `AryaAdapters` backs a "test connection" step.
`ConnectionProbe.adapter(command)` starts an adapter, sends `initialize` and `ping`, shuts it down,
and returns the adapter's name, capabilities, and the `initialize` round trip.
`ConnectionProbe.binding(command)` does the same for a binding's MCP server with `initialize`,
`notifications/initialized`, `tools/list`, and `ping`, and reports its tools and whether it serves
`history`. Neither throws: a failure comes back with one sentence for a person (could not start,
exited before answering, did not answer in time, a different protocol version), followed by the last
line the command wrote to stderr.
