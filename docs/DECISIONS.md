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

### 0019 — 2026-11-09 — Memory and routine payloads live in AryaMemory

The `Codable` payloads for `memory.*` and `routine.*` events are defined in `AryaMemory`, which
also projects them. `AryaLedger` stores them as opaque payloads. Why: `AryaMemory` depends on
`AryaLedger`, not the other way around, and a single owner avoids two types per event.

### 0020 — 2026-11-09 — No SwiftUI macros; colors are code, not an asset catalog

The command-line tools ship no SwiftUI macro plugin, so `@Entry`, `#Preview`, and other
SwiftUI macros do not compile. Use a classic `EnvironmentKey` with a computed
`EnvironmentValues` property, and no preview macros (preview fixtures are plain views and data).
Observation's `@Observable` does compile (its plugin is in the toolchain) and is the default for
app models on macOS 14; `ObservableObject` with `@Published` remains acceptable. Without Xcode
there is no `actool`, so color tokens are dynamic `NSColor`s defined in `AryaDesign` code that
resolve paper, ink, and Increase Contrast values from the effective appearance. Why: the app
must build with SwiftPM and the command-line tools only (0001, 0002).

### 0021 — 2026-11-09 — Write `@AryaState`, not `@State`

Extends 0020. The SDK declares a `State()` macro alongside the `State` property wrapper, and
`@State` resolves to the macro, which does not compile without its plugin. `AryaDesign` exports
`typealias AryaState<Value> = SwiftUI.State<Value>`; app code writes
`@AryaState private var isOpen = false`. `@Environment`, `@Binding`, `@FocusState`, and
`@Observable` are unaffected. Why: same toolchain constraint as 0020, with the smallest fix.

### 0022 — 2026-11-09 — Stewards can be resumed; runtime events have runtime payloads

The runtime adds event type `steward.resumed` (payload `{}`) so a paused steward can take
triggers again; `steward.paused` and `steward.retired` carry `{reason?}`, and `steward.created`
and `steward.charter.updated` carry `{charter, version, reason?}`. Like 0019, the payload
structs for `steward.*`, `run.*`, `action.*`, and `approval.*` live with their writer in
`AryaRuntime`; the ledger stores them as opaque JSON. Why: one writer per event type keeps the
shape and its tests in one place.

### 0023 — 2026-11-09 — Every payload lives with its writer; the ledger owns the envelope

Extending 0019 and 0022: `casebook.*`, `case.*`, `rehearsal.*`, `proposal.*`, and
`metric.recorded` payloads live in `AryaEval`. `AryaLedger` owns the `Event` envelope, `Actor`,
the `EventType` constants (including `steward.resumed`), the `EventPayload` protocol, and only
the payloads it writes itself: `env.read`, `system.repair`, and `system.started`. Writers may
conform their payload structs to `AryaLedger.EventPayload` (one `static let type`) to get
`EventDraft(payload, actor:…)` and `event.payload(as:)`. Why: one owner per shape, and no
lane waits on the ledger lane to add a field.

### 0024 — 2026-11-09 — `run.*`, `action.*`, and `approval.*` payloads live in AryaLedger

Supersedes the `run.*`, `action.*`, and `approval.*` part of 0022 at the project lead's
request: their payload structs (`RunStarted`, `RunFinished`, `ActionProposed`,
`ApprovalRequested`, `ApprovalGranted`, …) are defined once in `AryaLedger`, conform to
`EventPayload`, and match the shapes the runtime already writes (for example
`approval.requested = {approval, kind, action|question, to, expiresAt?}`), so the runtime, CLI,
and app decode one type instead of hand-parsing. `ProposedAction` moves to `AryaCore` (the
runtime keeps its `policyAction` extension). `steward.*` stays with the runtime (0022);
`memory.*` and `routine.*` with `AryaMemory` (0019); eval-written types with `AryaEval`
(0023). Payloads carry no `v` of their own: the envelope's `v` versions the line, and a
breaking payload change gets a new decision. Why: one decoder per event for every reader.

### 0025 — 2026-11-09 — Routine proposals are gated through `RoutineGateChecking`

A routine version goes live only through `AryaMemory.RoutineGatekeeper`: it sends a
`RoutineGateRequest` (steward, proposal, routine name, candidate and live versions, casebook
version) to a `RoutineGateChecking` gate and drafts `routine.promoted` (actor `system`) only
when the verdict passes. `RefusingRoutineGate` is the default. `Arya` wires the protocol to
`AryaEval`, which rehearses the live charter with `RoutineLibrary.candidateRoutines(for:)` in
place of the live routines and applies the same rule as charter gates (decision 0017). A person
may promote a failed version with `RoutineGatekeeper.override` (the person is the actor).
Run-proposed routines enter through `RoutineProposals.intake`, which stores content in blobs
before drafting `routine.proposed`. Why: `GateCheckRequest` names a charter version, and a
routine change must be rehearsable without minting a new charter version.

### 0026 — 2026-11-09 — Effort is an operational setting, not a gated proposal

A steward's effort (`low`, `medium`, `high`) says how hard its adapter should work, not what the
steward should do, so changing it does not go through a proposal or a gate. The facade exposes
`effort(for:)` and `setEffort(_:for:by:)`; the write appends `steward.effort.set {effort}`
attributed to the deciding person, and the runtime's steward projection folds it into the
live charter's `effort` without bumping the charter version. Every run and rehearsal records
the effort it used in `run.started`, so baselines stay comparable: a rehearsal at a different
effort is visible as such. Why: the header selector in the app must act at once, and effort
never changes instructions.

### 0027 — 2026-11-09 — Gates judge proposals by the live charter's rules

`AryaEval.RehearsalGate` scores both the baseline and the candidate with the live charter's
`scorer` and applies the live charter's `gate` settings, whatever the candidate says. When no
baseline exists for the live version and casebook version, the gate rehearses the live charter
first. Only rehearsals without a proposal serve as baselines. `ProposalDesk.accept` is the one
path that makes a candidate live: it requires a passing gate or a person's override, refuses a
proposal written against an older live version (`stale`), and records
`steward.charter.updated` followed by `proposal.accepted`. Why: a proposal must not loosen its
own gate, and a gate must never pass for lack of a baseline.

### 0028 — 2026-11-09 — Domain projections live with their writers on `LedgerProjection`

`AryaLedger` provides `LedgerProjection` (`init()`, `apply(Event)`), `Projected<P>` (value plus
the last folded `seq` and `hash`, refusing gaps and forks), and `LedgerReader.rebuild` and
`catchUp` (incremental, rebuilding from scratch if the ledger no longer continues from the
projection). The steward, run, and approval projections stay where they already are
(`StewardBook`, `RunBook`, `ApprovalBook` in `AryaRuntime`), like memory, proposals, and
rehearsals in their modules; they adopt `LedgerProjection` when the workspace lane wires the
ledger-backed `EventSink`. The ledger itself projects only `LedgerIndex` (counts, per-steward
counts, run spans). Why: the same reason as 0019, 0022, and 0023 (one owner per shape), and
duplicate projections in two modules would drift.

### 0029 — 2026-11-09 — Publishing under push races; one testable build in `just ci`

The first publish of a change runs the full `just ci` on a rebased `main`. If that push is
rejected and `git rebase origin/main` applies with no conflicts, re-check with
`just tidy && just build && just test <YourModuleTests>` and push right away; do this at most
three times, then run the full `just ci` again. A rebase with conflicts always needs the full
`just ci`. If `main` goes red, the lane whose commit broke it fixes it first (smallest fix);
any lane that notices may fix it. `just build` builds every target and test target once with
`--build-tests`, `just test` reuses that build with `--skip-build`, and tidy lints formatting
in parallel. Why: `main` moves faster than a full run, and plain `swift build` followed by
`swift test` compiled every module twice (testable and not); after a change in `AryaCore` the
full run went from 120 s to 59 s on the same machine.

### 0030 — 2026-11-09 — The runtime owns the `metric.recorded` payload

When a live run finishes, the runtime writes one `metric.recorded {metric, value}` per entry in
`run/result.measurements` (actor: the steward, run: the run), after the run's `run.decision`
events and before `run.finished`. Rehearsals record none. The typed payload is
`AryaRuntime.MetricRecorded`, not an eval type as 0023 said: the writer owns the shape, and the
runtime cannot import `AryaEval` (0015), while eval already imports the runtime. Why: eval's
metric series need real measurements, and one writer per event type keeps the shape stable.

### 0031 — 2026-11-09 — Routine actions are policy-gated and limited; sandboxing moves to M4

A `routine` action always goes through the charter's approval policy like any other action
kind, and is held for approval (`ask`) unless the charter's policy marks routines `auto` (a
rule for action kind `routine`). Running one keeps the limits from `ShellRoutineRunner`: a
timeout, the run's workdir, and a clean environment. A macOS `sandbox-exec` profile for
routines is planned for M4, no longer under Later. Why: routines are code a steward wrote for
itself, so a person approves them by default until real sandboxing lands.


### 0032 — 2026-11-09 — Routines are approved per name and version

The approval policy for routines is per routine, not per action kind; this replaces the
kind-level `routine` rule of 0031 (its runner limits and M4 sandboxing stand). A `routine`
action names its routine in `params.name`, and the runtime looks up that routine's live
version from the run's start. A policy rule `routine:<name>@<version>` decides that version
(`auto`, `ask`, or `deny`). A bare `routine:<name>` rule may only deny, and then it covers every
version. Every other routine is `ask`, whatever `policy.default` or a kind-level `routine` rule
says, so a new version asks again until the charter names it. A routine with no name or no
live version is denied (`no_routine_name`, `unknown_routine:<name>`). Why: a routine is code
the steward wrote; approving a name must not silently approve the next version of it.

### 0033 — 2026-11-09 — Swift builds and tests run in two machine-wide CI slots

Every lane builds in its own worktree on one machine, and unbounded parallel `swift build`
runs pushed the load past 200, so builds were killed (SIGTERM, SIGBUS) and runs collided.
Every swift build or test the repo's tooling starts now goes through `etc/scripts/slot.sh`:
it holds one of two lock files in the shared git dir
(`$(git rev-parse --git-common-dir)/arya-ci-slot-{1,2}.lock`) with `lockf(1)` for the
command's lifetime, tries each slot without waiting, and otherwise polls every two seconds,
printing `waiting for a CI slot`. `just build`, `just test`, `just screenshots`, and
`etc/scripts/bundle-app.sh` wrap their swift calls; `just ci` and `just publish` go through
those recipes, so they never hold a slot while waiting for another one. Builds pass `-j 6`.
`ARYA_CI_SLOTS` and `ARYA_JOBS` override the counts. Don't run swift build or test directly;
a build killed by a signal under load is not a code failure, so rerun it once before
debugging. Why: two concurrent builds keep the machine responsive and finish sooner overall
than ten builds fighting for 14 cores.

### 0034 — 2026-11-09 — Approval cards need Command for their keys

A focused approval card took plain Return as Approve and Escape as Deny. The card can take focus
on its own when the window activates, so a Return typed for something else granted a demo
approval. Approval cards now answer only Command-Return (approve) and Command-Delete (deny);
other primary buttons keep plain Return. STYLE.md Buttons notes the exception. Why: granting an
action is the one write that must never happen by accident, and the modifier costs one key.

### 0035 — 2026-11-09 — Stewards keep a plan

A run's `run/result.plan` (PROTOCOL.md: steps `{id, text, status, rationale?}` with status
`pending`, `in_progress`, `done`, `skipped`, or `blocked`) is the steward's whole plan. When a
live top-level or join run returns a plan whose ids, texts, or statuses differ from the current
one, the runtime records `plan.updated {items, reason?}` (actor: the steward, run: that run;
`reason` is the run's summary) after the run's decisions. Crew children and rehearsals never
change the plan; an empty plan means none, and a malformed one (empty or repeated id, empty
text) is ignored without failing the run. The next run's instructions show the current plan
under "Plan", and the finish rules ask for the whole plan whenever it changes. The payload
`PlanUpdated` and projection `PlanBook` live in `AryaRuntime`, the only writer; read models
adapt to it. Why: a steward owns an outcome over many runs, so it needs a durable plan it can
revise, not only one-shot decisions.

### 0036 — 2026-11-09 — Clean single-canvas workspace

Supersedes the paper palette and serif headings of 0020 (its toolchain notes still hold) and the
boxed dark components drafted after it. The window is one near-black canvas with a hidden,
transparent title bar; the sidebar, page, and an on-demand inspector are separated by single
hairlines, never by fills, cards, or bands. Each screen has one purpose and one orange primary
action; secondary detail moves behind disclosure, hover, or the inspector. Stewards are listed
on the left with their runs as threads titled by summary, never by number or id; a steward page
has at most four tabs (Overview, Improve, Knowledge, Ledger) and no header band; effort and
other settings live in the inspector. Type is the system sans for interface text and the system
monospace for machine text, with small uppercase labels and no serif; spacing is on a 4 pt
grid. The app opens dark whatever the system setting; Light is a setting. Why: the app had grown
boxed, banded, and repetitive; one canvas with type-driven structure carries the same
functionality with far less noise.

### 0037 — 2026-11-09 — Actions carry risk; stewards have an autonomy level

A charter may set `autonomy`: `observe` (actions are recorded and refused), `suggest` (every
action asks), `act_low` (low-risk actions run, others ask), or `act_medium` (low and medium
run, high asks). Without it the policy alone decides, as before. An action's risk comes from
the charter's `policy.risk` entries `{action?, binding?, level}`, where `action` is a kind or
`routine:<name>`: the most specific entry wins (action and binding, then action, then binding),
`medium` when none matches, and the adapter's `risk` hint can raise it but never lower it.
With autonomy set, structural refusals and deny rules stay deny; with no matching rule,
autonomy decides; a matching rule can only tighten what autonomy allows; an unlisted routine
still asks (0032). `action.proposed` records `risk` and `autonomy`, and its `reason` is
`autonomy:<level>:<risk>` when autonomy decided, so an approval card can say why it asked.
`Risk`, `Autonomy`, and `RiskRule` live in `AryaCore`; the new fields are omitted when unset,
so existing charters and lines encode byte for byte as before. Why: a steward that owns an
outcome should act on safe steps by itself and ask only where the risk warrants it.
Amended: with no `policy.risk` entry an action's kind sets its default risk (`Risk.defaults`:
`label`, `route`, `tag`, `note` low; `reply`, `message`, `email` medium; `refund`, `close`,
`delete`, `pay`, `merge` high; any other kind medium), and the adapter's hint can still only
raise it, so a hint never makes a refund look safe. `Workspace.risk(kind:binding:steward:)`
reads the same resolution for the New steward sign-off list and approvals.

### 0038 — 2026-11-09 — Visual checks use offscreen snapshots

Agents never launch the app window on the user's machine: no `just app`, `just run-app`, or
`open` of the bundle, and nothing that shows a window, a Dock icon, or takes focus. A visual
check is `just snapshot`, which seeds or reuses `.build/demo-home` and renders every key state
(first launch, Overview, a run thread, a run with an approval, Needs you, Improve, Knowledge,
Ledger with the inspector, and the New steward flow) at 1400 × 1000 pt in dark and light to
`.build/snapshots/<state>.png` through `NSHostingView.cacheDisplay` inside a test process.
Sheets render as standalone pages because they do not draw offscreen. Why: a window launched
by an agent steals focus from the person using the machine, and offscreen PNGs on seeded data
are reproducible and reviewable.

### 0039 — 2026-11-09 — People reach stewards through a local inbox

A person messages a steward through one of the charter's person bindings, with an intent:
`ask`, `correct`, or `handoff`. `Inbox.post` records `inbox.message {from, channel, intent,
text, note?}` (actor: the person) for every accepted message, refusing unknown stewards,
senders that are not person bindings, and empty text. A correction also becomes a
`memory.added` note authored by the person, tagged `correction`, with the message as its
provenance event (skipped when it repeats a live note). When the charter has a matching
`message` trigger and takes live triggers, the message starts a run whose input names the
sender and intent and attaches `{kind: inbox, message, from, intent}`; the note is in that
run's memory. The steward answers with an action through the same person binding, whose
`action.executed` output is the inbox entry; `InboxBook` threads both directions per steward.
Email or chat channels come later as MCP bindings that feed the same `Inbox.post`. Why: a
steward that owns an outcome has to take questions, corrections, and handed-off work from
people, and corrections must stick.

### 0040 — 2026-11-09 — Routines and binding servers run sandboxed

On macOS, arya runs routine scripts and live binding MCP servers under `sandbox-exec` with a
profile that allows reads, allows writes only under the run's workdir (and `/dev/null`,
`/dev/tty`, descriptor devices), and denies the network unless the binding sets
`network: true` (routines never get it). Binding servers are confined through the binding
proxy (`--sandbox <workdir>`) and the action executor (`BindingActionExecutor.sandboxed`).
A sandboxed run records `run.started.sandbox {kind: sandbox-exec, workdir, network: [binding
ids]}`; when `sandbox-exec` is missing or cannot apply a profile (arya already sandboxed), the
processes run as before and nothing is recorded, so the ledger never claims a sandbox that was
not there. Adapter harnesses are confined through the adapters' protocol: when the adapter
reports capability `sandbox: "os"`, `run/start.sandbox` carries
`OSSandbox.confiningWrites(to: workdir)` (writes only in the workdir; network allowed, since
harnesses call hosted models), and every sandboxed run records `run.sandboxed {harness: os |
workdir | none}` after the handshake, so the ledger says how far the harness was confined.
Why: a steward acting on its own should not be able to write or reach anything its charter
did not grant.

### 0041 — 2026-11-09 — Publishing: union-merged lane files, a docs-only fast path, and priority

Publishes were losing most of their time to rebase conflicts and full `just ci` runs waiting for
the two CI slots (decision 0033). Three rules: lane files (`docs/lanes/*.md`) merge with git's
`union` driver (`.gitattributes`), so appended Log and Questions lines never conflict; lanes
append and edit only their own lines there. `just publish` takes a fast path when every commit
ahead of `origin/main` touches only `docs/**` or `*.md`: `just tidy` (format, secrets, denylist)
and push, rebasing up to ten times, with no build or test, because such changes cannot affect
the Swift build. It never prompts and prints each step with its elapsed time, so it runs in the
background; agents publish that way. Until the app redesign (M3.5) passes review, its lanes
publish freely and other lanes batch to at most one publish every 45-60 minutes. Why: fewer
full CI runs and no lane-file conflicts free the slots for the work that matters now.

### 0042 — 2026-11-09 — Email and chat reach stewards through relay bindings

A person binding may set `via`: the id of an MCP binding (an email or chat server) that relays
messages to and from that person, with the person's `channel` as their address there. Inbound,
`Inbox.pull(relay, steward:)` calls the relay's `receive` read tool, which returns
`{messages: [{from, text, intent?}]}`, and posts each message from the person whose channel
matches `from` (unknown addresses, empty text, and unknown intents are skipped and counted),
so relayed messages trigger runs and corrections become memory exactly like local ones;
`inbox.message` records `via`. Outbound, an action through such a person binding calls the
relay tool named by the action kind with the params, `target`, and `to` (the address); its
`action.executed` output is the inbox entry plus `via` and the relay's `result`, so
`InboxBook` threads both directions. A missing relay fails with `unknown_relay:<id>`. Person
bindings now keep their `actions` in the encoded charter when they have any. The relay is
responsible for returning each message once. Why: people work in email and chat, and a steward
that owns an outcome has to meet them there without a second message path.

### 0043 — 2026-11-09 — Crew children get bounded budgets and are recorded as delegations

A `run/result` delegation may ask for an `adapter`, an `effort`, and `limits` (any of
`maxTurns`, `timeoutSeconds`, `maxCostMicros`) for its child run. arya caps all of them at
the parent's: the adapter must be the charter's own or listed in the new `crew.adapters`, a
higher effort becomes the parent's, and each limit is the smaller of the asked and the
parent's (at least 1). Policy, autonomy, risk, and sandbox are always the parent charter's, and
children still only propose. Each delegation records `run.delegated {delegation, title,
child?, adapter?, effort?, limits?, refused?}` on the parent run (actor: the steward) before
its child starts; a delegation asking for an unlisted adapter or an unknown effort is refused
there (`adapter_not_allowed:<name>`, `unknown_effort:<value>`) and reported to the join run as
`refused:<reason>`. The child's `run.started` records its parent and the adapter, effort, and
limits it ran with, so replay rebuilds the same child. Why: sub-agents are only safe to hand
work to when they can never get more budget, reach, or authority than the run that asked.

### 0044 — 2026-11-09 — Dense keyboard-first workspace

The app reads as a dense, keyboard-first developer workspace. The type scale is smaller: 12 pt
UI text at about 1.35 line height in lists, a `prose` role at 1.45 for reading text, 11 pt
mono, 10.5 pt gutters and metadata, 9.5 pt uppercase labels, a 15 pt steward title, and a
16 pt KPI value. Rows are 24 pt and section gaps 12 to 16 pt. The window has three zones on
one canvas: the sidebar (232 pt), the stream (it fills the width between the sidebar and the
inspector, with no max-width cap on lists or threads), and a persistent inspector (340 pt,
hairline-separated, Option-Command-I hides it). The inspector follows the selection: a ledger
event's payload and hash, a run's facts and cost, else the steward's context (plan, schedule,
policy, connections, people, effort), with Settings as its last section. A command palette
and a status bar follow. Why: the larger, column-bound layout left most of the window empty
and hid function behind navigation.

### 0045 — 2026-11-09 — Charters name who may approve which actions

`policy.approvers` lists `{action, binding?, people, note?}` rules: `action` is a kind,
`routine:<name>`, or `*`; `people` are `local` (the person at this home) or person binding ids.
The most specific rule decides (kind and binding, kind, `*` and binding, `*`). With no rule,
anyone who can see an approval may decide it, so existing charters are unchanged. Only
granting is gated: denying is always allowed, and questions are not gated. A grant the rule
refuses records `approval.refused {approval, by, people, rule, note}` (actor: that person) and
leaves the approval pending. Why: a steward that can act on money or customers needs a record
of who was allowed to say yes, not only who did.

### 0046 — 2026-11-09 — Stewards re-plan after setbacks, a bounded number of times

When an action a steward proposed does not happen (an auto action fails; a person denies it
or lets its approval expire; an approved action then fails), arya starts a `replan` run of
that steward (`parent` = the run that hit the setback, actor: system). Its input lists each
setback (`kind`, the action, the error or the person's note) as text and as attachments, its
instructions carry the current plan, and a changed plan is recorded as `plan.updated` with
reason "Re-planned after …: <summary>", so the Overview plan shows why it changed. A chain of
re-plans from one run is bounded by the new `limits.maxReplans` (default 2, omitted from
charters at the default); past it, `run.replan.refused {setbacks, reason}` is recorded on the
run that hit the setback. Only active stewards re-plan, and never from rehearsals, crew
children, or replay (a re-plan is replayed as its own recorded run). Re-plan runs propose
actions through policy as usual. Why: a steward that owns an outcome must react when its
plan meets reality, but must not loop.
