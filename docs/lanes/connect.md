# Lane: connect

Owns `Sources/AryaApp/Features/Connections`, `Sources/AryaApp/Features/People`,
`Sources/Arya/Connections.swift`, and their tests (`Tests/AryaAppTests/Connections*Tests.swift`,
`Tests/AryaAppTests/People*Tests.swift`, `Tests/AryaTests/ConnectionTests.swift`). Binding and
credential pieces in `AryaAdapters` and `AryaRuntime` are asked for through those lanes'
Questions.

Goal: **stewards connect to systems and work with people where they work, end to end in the
app.** A person can see every system a steward can reach and what it may do there, connect or
disconnect it, test it, and keep its secret in the Keychain; name the people a steward works
with and what they may approve; message a steward and see its replies as threads; hand it work;
and receive a periodic report from it.

## Backlog

- [x] Connections page (Settings → Connections…, Go → Connections, Shift-Command-K): every
  known system connection with its command, read tools, action kinds with risk, network flag,
  and the stewards connected to it; adapters and their stewards; Connect and Disconnect for
  the chosen steward as gated charter proposals; Test starts the server and lists its tools
  against the declared ones; secrets saved to and removed from the Keychain, never a file or
  the ledger. Snapshot `connections-*`.
- [ ] Credentials reach live binding servers: the runtime passes `ARYA_CREDENTIAL` from a
  `CredentialStore` when it starts a binding's server (asked of runtime and workspace).
- [x] People page (Settings → People…, Go → People, Shift-Command-P): each person's name,
  role, reach (local inbox or an address on a relay), what they may approve, and their
  messages; add, edit, and remove as gated charter proposals; approval cards name who may
  approve the action. Snapshot `people-*`.
- [x] Channels: each person's thread on People (their `inbox.message` events, the steward's
  deliveries to them, and reports sent to them), with a composer that writes as that person
  ("Message as Sam", Ask, Correct, or Hand off) through the facade's
  `message(steward:text:intent:by:)`. Snapshot `people-thread`.
- [x] Hand off work: a hand-off is a task in the person inspector with the status of the run
  that took it (queued, running, needs approval, done, failed).
- [x] Periodic report: a charter `report` block (who, cadence, weekday, UTC hour); the
  facade's `reportDigest`, `sendReport`, `dueReports`, and `sendDueReports` (called by the serve
  loop) build the digest from the outcome trend and recap and record `report.sent`; People's
  Report section shows the schedule, the next report, Send now, and a gated form. Snapshot
  `people` (Report section) and the report in `people-thread`.
- [ ] Reports and replies reach relay people (email/chat) through their relay's send tool, not
  only the ledger (asked of runtime).
- [ ] e2e steps for each item (with cli-e2e).

## Decisions

- 2026-11-10: A connection's secret is stored per binding id in the login Keychain (generic
  password, service `arya.connection`) and reaches its MCP server as the environment variable
  `ARYA_CREDENTIAL`; one secret per connection is enough for token-based servers. Tests and
  snapshots use `MemoryCredentialStore`, so no test touches the real Keychain.
- 2026-11-10: The catalog is read from the ledger: every MCP binding any charter ever declared
  (latest declaration wins), so a system once connected stays one click away. Connect copies
  the binding into the steward's live charter; Disconnect removes it; both are charter
  proposals through the gate, never in-place edits. Disconnect is refused while a person
  binding relays through the connection (`via`).
- 2026-11-10: A connection test is a diagnostic, not a run: it starts the server with the app's
  environment plus the secret, lists tools with a 10 second limit, and records nothing. It
  runs the adapters lane's `ConnectionProbe.binding` (initialize, tools/list, ping) through the
  facade's `ConnectionTest`, which adds the declared-tool check; the page shows the server,
  latency, tools, missing tools, history support, or the probe's one-sentence problem.
- 2026-11-10: The Connections page is a main-pane destination (`Destination.connections`)
  rather than a steward tab, since connections span stewards; it keeps the steward it acts on.

- 2026-11-10: Person bindings carry optional `name` and `role` in `AryaCore.CharterBinding`,
  omitted when unset so existing charters encode byte for byte as before. What a person may
  approve is the governance lane's `policy.approvers` (already enforced): the page lists the
  unscoped rules naming them, and an edit sets exactly those rules. A rule left with no one
  names `local`, never opening it to anyone; a new rule lists `local` and the person. Editing keeps the binding id stable (message triggers name it) and
  every field the page does not manage (reply actions); removing a person also drops message
  triggers from them.

- 2026-11-10: A person's thread is read from the ledger in the app (`PeopleThread`), the same
  fold as runtime's `InboxBook`, plus `report.sent`; a hand-off's run is the one whose
  `run.started` input attaches the message id. "Message as Sam" passes the person binding as
  `by`, so the message is recorded in their name and a hand-off starts a run as them. No second
  message API: the app uses workspace's `message(steward:text:intent:by:)`.
- 2026-11-10: A report is one `report.sent` event per send, addressed to each recipient's
  person binding (channel and relay), with the digest text; that event is the delivery for the
  local inbox and the record for relays until runtime sends through them. The digest covers
  everything since the previous report: the metric against its target with the change over
  the period, counts of runs, decisions, and actions, the last three actions, failures, and
  approvals waiting. A charter without `report` sends nothing; the app still previews a weekly
  digest to every person. Due means the latest slot (UTC hour, on the weekday for weekly) has
  passed with no report since, so a missed slot sends once, not once per missed period.

- 2026-11-10: `arya message` and `arya report show|send` are connect-owned CLI commands in
  `Sources/AryaCLI/PeopleCommands.swift` (logged in cli-e2e.md), so the demo seeds real threads:
  Sam and Priya ask, correct, and hand off work on the triage and refunds stewards, each answer
  is a `reply` through their person binding (auto for team members), and the triage, refunds,
  and digest charters send weekly or daily reports. The `people-thread` snapshot renders the
  demo home as seeded; only `people-thread-live` adds a hand-off whose run is still going.
- 2026-11-10: A person's thread shows a working line (live dot, the adapter's latest status or
  tool call, step count) while a run started by their message has not ended and waits on no
  approval; new entries fade in. Thread lines name the steward and the run's title, never raw
  ids; statuses and tags are plain mono text. Remove sits behind More with a confirm, and
  Message is the row's one primary button.

## Questions

- (to runtime) Relay delivery: when a report or reply goes to a person reached `via` a relay,
  call the relay's send tool with the person's address and the text, and record the result
  on `report.sent` (today it is recorded only).
- (to cli-e2e) `arya message <steward> --as <person> [--intent ask|correct|handoff] <text>` and
  `arya report send|show <steward>` over `Workspace.message` and `sendReport`/`reportDigest`,
  so the demo can seed a real conversation instead of the snapshot's fixture events.
- (from runtime) Relay delivery is in (decision 0050): `sendReport` starts a report run (`RunEngine.report`) for relay recipients, one `send` action each under policy and approvals; `report.sent.run` names it (integration edit in `Reports.swift`). Relay person bindings need `send` in their `actions`.
- (from workspace) live: `message(steward:text:intent:by:)` with `by` a person id, and `conversation(steward:person:)` (inbound and outbound, newest last).

## Log

- 2026-11-10: Busy demo and a live thread. `arya message` and `arya report` seed Sam's and
  Priya's conversations, hand-offs, and reports across three stewards; a working line shows a
  hand-off's run in progress; reviewer defects (a) to (e) fixed. (d) and (e) came from the
  old snapshot fixture (seeded report text and an extra approval); `people-thread` now renders
  the demo home itself, so reports come from `reportDigest` and counts from the workspace.

- 2026-11-10: Channels, hand-offs, and periodic reports. People shows each person's thread and
  a "Message as" composer; the inspector lists their hand-offs with run status; the Report
  section sets a charter `report` and previews the next digest. Facade `Reports.swift`, AryaCore
  `ReportConfig`, and a one-line serve-loop integration edit (`sendDueReports`). Demo triage
  charter sends Sam a weekly report.
  Visual check (`people-thread`, `people`, dark and light): Sam's thread reads top to bottom
  with ask, correct, hand off, reply, and report tags, the steward's lines in the accent; the
  composer sits under the thread with Ask, Correct, Hand off and "Message as Sam…"; the
  inspector lists hand-offs as queued, needs approval (warning), done (green); the Report row
  shows "Weekly on Mondays at 09:00 UTC to Sam." with the next digest in mono. Dropped the
  "ratio" unit from report numbers after the first look.

- 2026-11-10 HANDOFF: Connections (c955cdb) and People are on main. Next is Channels and hand
  off work. Plan: add `Workspace.postMessage(text, from:, to:, intent:)` over
  `Inbox.post` in a new `Sources/Arya/Channels.swift` (the facade has only `deliverMessage`,
  which records nothing when no trigger takes it); add `FeatureWrite.postMessage`. On People,
  show each person's thread: `inbox.message` inbound, and `action.executed` whose output has
  `inbox` for outbound. Add a composer ("Message as Sam", intent Ask, Correct, or Hand off).
  List handoffs as tasks, with status from the run whose `run.started` input attachment names
  the message id. Then the periodic report (item 4). Notes: Command Line Tools need
  `@AryaState`, not `@State` (decision 0021). Snapshots reuse `.build/demo-home`, so run
  `just demo --no-open` after you change examples.

- 2026-11-10: lane opened; Connections page with Keychain secrets, connection test, and
  gated Connect/Disconnect.
- 2026-11-10: Visual check: `connections` and `connections-light` snapshots on the demo home
  show triage's inbox (search, get; label low, route low, reply medium; secret stored) and
  billing (refund high; secret field), the steward choice, and the three adapters.
- 2026-11-10: Connections page pushed (025e13d).
- 2026-11-10: People page, person `name`/`role`, approvals through `policy.approvers`, and
  approvers on approval cards.
  Visual check: `people` snapshot on the demo home shows Sam (support lead, inbox, approves
  reply, no messages yet), Edit, Remove, and Add person.
- 2026-11-10: Test now uses the adapters probe (`ConnectionTest` over `ConnectionProbe.binding`).
- 2026-11-10: Review R3/R7: Test quiet, Connect the one primary, Disconnect behind More with a
  confirmation, reads and actions as one mono line, a "For steward: … ▾" picker, and the
  inspector follows the selected connection (capabilities, users, secret, last test).
  Visual check: `connections`, `connections-connect`, `connections-inspector` snapshots.
