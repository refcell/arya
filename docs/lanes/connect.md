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
- [ ] Channels: conversations with people (local inbox and email/chat relays, decision 0042)
  as threads on the steward, with the steward's replies; send a message from the app.
- [ ] Hand off work: a person assigns a task ("take this ticket") that becomes a run trigger
  and shows as a task with status.
- [ ] Periodic report: a digest from the recap and metric trend sent to chosen people through
  a channel, configured in the charter.
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

## Questions

## Log

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
