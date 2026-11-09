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
| `sandbox` | `"workdir"` if the harness's built-in write tools are confined to `workdir` or off, `"none"` if they cannot be restricted |

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
  "resultSchema":{"…":"JSON Schema of run/result.result"}}}
```

Result: `{"session":"<adapter session id>"}`. The adapter then works asynchronously.

- `input.kind` is `manual`, `schedule`, `message`, `case`, or `join`.
- `tools` are MCP servers to hand to the harness. They are arya's binding proxies, not the real
  systems: they expose only read tools and record every call. Adapters pass them through
  unchanged and must not add other tools that reach external systems.
- `workdir` is a fresh scratch directory owned by the run. The adapter runs the harness there.

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
   "decisions":[{"id":"d1","choice":"…","rationale":"…"}],
   "actions":[{"id":"a1","kind":"comment","binding":"tracker","target":"tracker:ISSUE-1",
               "params":{…},"rationale":"…"}],
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

## Requests (adapter → arya)

### `host/ask`

`{"session":"…","question":"…","to":"person:alex"}` → `{"answer":"…"}`. The adapter asks a
person a question (`to` is optional; the default is the local user). arya shows it in the
approval queue until it is answered or the run's timeout passes (`"answer": null`). In
rehearsal and replay the answer comes from the recording; an unrecorded question in rehearsal
answers `null`.

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

## Reference adapters

- `arya-fake-adapter --script <file>`: replays a JSON script of events and results keyed by
  input text. Deterministic; used by every test and by the demo.
- `arya-exec-adapter --profile <name>`: wraps a command-line agent. A profile names the command,
  arguments per effort, how the prompt is passed (stdin or argument), how MCP tools are passed
  (a config file in `workdir` or none), and how output is parsed: `text` (the last fenced
  ```` ```json ```` block is the result) or `jsonl` (one event per line, the last object with a
  `result` key is the result). Example profiles cover the non-interactive print modes of common
  command-line agents such as Claude Code and Codex CLI.

```json
{"v":1,"profiles":{"exec-default":{"command":"claude","promptVia":"stdin","parse":"text",
  "args":{"low":["-p"],"medium":["-p"],"high":["-p"]},"mcpConfig":"none"}}}
```

## Fake adapter scripts

`arya-fake-adapter --script <file>` and the in-process `FakeAdapter` run the same server from a
JSON script. `run/start` picks the run whose `input` equals `input.text`, else the run without
`input`; with neither it fails with `-32004`. The session id is `fake-<run>`.

```json
{"v":1,"adapter":{"name":"fake","version":"0.1.0"},
 "capabilities":{"effort":["low","medium","high"],"send":true,"cost":true,"transcript":true,
                 "tools":"none","sandbox":"workdir"},
 "runs":[
  {"input":"New issue: login page times out",
   "steps":[{"event":{"kind":"message","role":"assistant","text":"Looking."}},
            {"sleepMs":50},
            {"ask":{"question":"Assign to Alex?","to":"person:alex"}}],
   "status":"completed",
   "result":{"summary":"Labeled ISSUE-7.","decisions":[{"id":"d1","choice":"bug"}]},
   "cost":{"inputTokens":120,"outputTokens":40,"costMicros":900}},
  {"steps":[{"crash":{"exitCode":3}}]}]}
```

`adapter` and `capabilities` are optional (the defaults are shown). Per run, every field but
`steps` is optional: `status` defaults to `completed`, `result` to none, `cost` to zeros.
`startError` (`{"code":…,"message":…}`) makes `run/start` fail; `ignoreStop: true` acknowledges
`run/stop` without sending `run/result`, to test termination. Steps run in order, each with one
key:

| step | effect |
| --- | --- |
| `event` | emit a `run/event` with the next `seq` |
| `sleepMs` | wait that many milliseconds |
| `ask` | send `host/ask`, wait, then emit the answer as a `message` event with role `human` |
| `stdout` | write the text as one raw stdout line (a protocol error) |
| `crash` | exit with `exitCode` without a `run/result` |
| `hang` | produce nothing until `run/stop` |

After the last step the adapter sends `run/result`. `run/send` emits the message as a `message`
event, and `run/stop` ends the run with `status: "stopped"`.

## Host behavior

arya's client (`AdapterConnection` in `AryaAdapters`) enforces the timing rules above: a request
fails after 30 seconds without a response; after `run/stop`, sent by a person or by the idle
timeout, the adapter has 10 seconds to send `run/result` before SIGTERM and, 5 seconds later,
SIGKILL; after `shutdown` it has 5 seconds to exit. A stdout line that is not a JSON-RPC message
is recorded as received and reported as a protocol error; the runtime decides whether it fails
the run. A request from the adapter other than `host/ask` gets `-32601`.

## Conformance

The conformance suite in `Tests/AryaAdaptersTests` runs the protocol against any adapter
binary:

```sh
ARYA_ADAPTER_CMD="path/to/adapter args" just test AdapterConformance
```

It checks the handshake, version negotiation, one-run-per-process, `seq` ordering, exactly one
`run/result`, `run/stop` within 10 seconds, error codes, and clean exit on `shutdown`. Without
`ARYA_ADAPTER_CMD` it runs against `arya-fake-adapter`.
