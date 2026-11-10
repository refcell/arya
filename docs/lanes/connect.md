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
- [ ] People directory: the people a steward works with (name, role, channels, what they may
  approve), editable as a gated charter proposal, used by approvals and channels.
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
  environment plus the secret, lists tools with a 10 second limit, and records nothing.
- 2026-11-10: The Connections page is a main-pane destination (`Destination.connections`)
  rather than a steward tab, since connections span stewards; it keeps the steward it acts on.

## Questions

## Log

- 2026-11-10: lane opened; Connections page with Keychain secrets, connection test, and
  gated Connect/Disconnect.
- 2026-11-10: Visual check: `connections` and `connections-light` snapshots on the demo home
  show triage's inbox (search, get; label low, route low, reply medium; secret stored) and
  billing (refund high; secret field), the steward choice, and the three adapters.
