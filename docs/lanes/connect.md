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
- 2026-11-10: Person threads read `Workspace.conversation(steward:person:)` through
  `FeatureWorkspace.conversation` (cached in `FeatureStore.conversations`, reloaded as the
  ledger grows); reports, hand-off tasks, and the working line still fold the ledger, since
  the facade has no read for them. Until the read loads (and in offscreen snapshots) the app
  folds the ledger the same way. `InboxBook` now also counts an executed action proposed on a
  person binding as a delivery (charter people, or anyone who wrote first), so dry-run and
  relayed replies appear in the facade's thread too (integration edit in AryaRuntime).
- 2026-11-10: The person inspector shows who (name, role), reach, approvals, message counts,
  reports received, hand-offs with status, and the last three messages; the connection
  inspector shows the people a relay carries per steward and the last messages it carried in.
  Visual check: `people-thread` shows the person inspector with Reports "1 sent · last Nov 9",
  the needs-approval hand-off, and the last three messages; the weekly report reads "Reply Sam".
  Moves (5) busy demo and (2) no dead space in the inspector. The demo has no relay, so the
  connection inspector's Carries line is covered by tests only.
- 2026-11-10: Connections and People at the new density with the shared control set. A
  connection row is two lines: id, last test with a status dot, a 7-day call sparkline and
  count, Test and Connect or Disconnect (secondary, Disconnect confirms); then reads, actions
  colored by risk, stewards, secret, network. Calls come from the ledger
  (`ConnectionActivity`: adapter tool calls named `binding.tool`, and actions proposed on the
  binding with how they settled). Secret entry moved to the inspector, which also lists recent
  calls; its one primary is Test connection. A steward picker is a segmented control for up to
  four stewards. People rows show open hand-offs, last activity, reach, approvals, counts, and
  reports, with Message and an ellipsis menu (Edit, Remove with confirm).
- 2026-11-10: Channels are a pane on People (People | Channels, `NavigationState.peoplePane`):
  the local inbox and each relay someone is reached through, with status (local; bound and
  the last test; not in the charter), people, in and out over 7 days with a sparkline, and the
  last message (`PeopleChannels`, built from each person's thread). The demo's triage steward
  gains a `chat` relay and Lee (on-call engineer) reached through it, so the pane has a relay.
  Visual check: `connections-detail` (rows with test, sparkline, risk-colored actions; recent
  calls below; inspector with recent calls, secret, Test connection), `people-channels` (inbox
  and chat with volume, recent messages across channels), and `people-thread` (dense rows,
  segmented steward picker and composer, ellipsis menus). Moves (2) no dead space, (3) real
  controls, and (5) busy demo.
- 2026-11-10: Review 11 fixes. Per-row Connect and Message are secondary (no orange per row).
  People always shows a person: with none chosen the first one's thread opens and the
  inspector shows them (focus `.person("")` stands for the first person). Connections lists
  the selected steward's bindings, with This steward | Show all. Action kinds read through
  `ActionWords.kind` and person targets by name. Visual check pending: no snapshot state
  filter yet and the CEO bars full renders while load is over 30.
- 2026-11-10: All stewards scope (CEO framing decision). Connections and People open on All
  stewards; the picker reads "All stewards ▾". Connection rows say "used by A, B +2"; person
  rows list the stewards and departments they work with (`PeopleRoster`; departments come
  from the stewards' charters, a person has none of their own), and Message opens their
  thread in their first steward's scope. A steward scope folds the rest under a collapsed
  "Not used by this steward (N)" / "Not with this steward (N)" with a quiet Add to steward…
  (no per-row orange). Add to steward… prefills the person form and drops a relay the steward
  lacks. Report "(executed)" on drafted replies came from a demo home seeded before the
  runtime's drafted flag (afc02209); a re-seed reads "(drafted, not sent)". Visual check
  pending the snapshot state filter (load over 30).
- 2026-11-10: Review 13. Connection tests stay a session diagnostic (never recorded), so the
  seed cannot record one; instead a connection with no test this session shows the ledger's
  evidence, "working · last call 9h ago" (or "last call failed"), and a local server (no
  network) reads "no secret needed". A relay counts what it carries: replies proposed to a
  person it reaches and messages in through it (chat: 5 calls in 7d). People: "approves …"
  only for approvers; message counts everywhere come from the thread fold (`tally`), each
  person's stewards are ordered most-talked first so Lena opens on Product adoption, and the
  inspector says which steward its counts cover. Adapters render as rows. Added
  `ARYA_SNAPSHOT_STATES` (comma-separated page states) to SnapshotTests so a lane renders
  only what it changed. No seed change was needed, so nothing to coordinate with cli-e2e.
- Visual check (2026-11-10, connections, people, people-thread, connections-detail): every
  used connection green with its last call, chat 5 calls; All stewards People lists 9
  people with in/out counts, Lena 1 in on row and inspector; only Sam shows approves. Moves
  (4) live feel and the review-13 consistency items.
- 2026-11-10: M3.6 #6 and #17. Attribution: the facade's note provenance names people by
  their charter name ("From Sam's correction.", "Alex's preference, added by Alex"), so
  Knowledge and every other reader say who corrected what; People shows "taught N" on rows
  and a LEARNED FROM list in the person inspector (`PeopleLearned`: notes a person authored,
  any steward, with source and steward). Reports is a third People pane per steward (decision:
  a pane, not a steward tab, since app-shell owns tabs and STYLE caps segments at four):
  cadence, next and last send, the next report from the real digest, Send now (the screen's
  one primary; relayed sends run as a report run under policy), and past reports with each
  recipient's delivery (`PeopleReportHistory`: inbox, sent, drafted, waiting, denied, failed).
  app-shell's `ARYA_SNAPSHOT_STATES` filter (`just snapshot <state>...`) replaced the one
  connect added earlier today.
- Visual check (2026-11-10, reports, people-learned): Reports shows "Weekly on Mondays at
  09:00 UTC to Sam, Priya", next 16 Nov 09:00, the digest with routed_within_1h 0.96 vs 0.95
  and "(drafted, not sent)", one past report delivered to both inboxes; people-learned shows
  Lee's correction under LEARNED FROM LEE and "taught 1" on Lena, Sam, Lee. Moves (4) live
  feel and M3.6 #6, #17.

## Questions

- (from app-views) Adapter display names: one shared helper, `AdapterName.display(_ profile:, named:)` in Features/Support/AdapterName.swift. Pass your catalog display name as `named` (or tell me the read and I will wire it in); without one it reads the id in words.

- From app-shell, 2026-11-10 (CEO: stop FeatureWorkspace collisions): FeatureWorkspace.swift
  is split by lane. Add your reads (requirement plus default) to `FeatureConnectReads` in
  `Features/Support/FeatureWorkspace+Connect.swift`; `FeatureWorkspace` inherits it, so conformers are unchanged.
  Core reads and writes stay in FeatureWorkspace.swift (app-shell).

- (to runtime) Relay delivery: when a report or reply goes to a person reached `via` a relay,
  call the relay's send tool with the person's address and the text, and record the result
  on `report.sent` (today it is recorded only).
- (to cli-e2e) `arya message <steward> --as <person> [--intent ask|correct|handoff] <text>` and
  `arya report send|show <steward>` over `Workspace.message` and `sendReport`/`reportDigest`,
  so the demo can seed a real conversation instead of the snapshot's fixture events.
- (from runtime) Relay delivery is in (decision 0050): `sendReport` starts a report run (`RunEngine.report`) for relay recipients, one `send` action each under policy and approvals; `report.sent.run` names it (integration edit in `Reports.swift`). Relay person bindings need `send` in their `actions`.
- (from workspace) live: `message(steward:text:intent:by:)` with `by` a person id, and `conversation(steward:person:)` (inbound and outbound, newest last).
- (to cli-e2e, FYI, CEO unblock 2026-11-10) Connect added, append-only: e2e steps 54-58 (`run
  crew`, a run proposing `flag-duplicate-charges`, `routine library`, `routine adopt` into
  st_refunds, the library showing both stewards on one version; group `library`), and the demo
  seeder's shared routine (`Sources/AryaDemo/SharedRoutine.swift`, `.shareRoutine` step):
  triage proposes `spot-duplicate-charges`, its gate promotes it, Priya adopts it into refunds,
  and nine runs across both stewards execute it (7 executed, 1 failed, 1 denied). The demo
  seed stamp changes, so the next `just demo` reseeds.
- (to runtime) Shared routines: connect's `Workspace.adoptRoutine` (decision 0060) proposes a
  version to another steward and gates it there, and each steward stays pinned to its own live
  version. If your shared-routine backend changes how a version is shared or pinned, tell me
  the facade call and I'll move the library's Use in steward… and Update to … onto it.
- (from workspace) `learnedFrom(person:) -> LearnedFromSummary{items[{id, kind note|correction|review, text, steward, at, source, live, caseID}], taught, corrections, reviews, stewards, summary}` across stewards (notes authored, cases corrected, cases reviewed; matches `person:x` and `x`), cached; it can replace PeopleLearned's own projection.
- (from runtime) Per-person memory (decision 0061): `Workspace.personMemory(person:)` (`alex` or `person:alex`) lists preferences and corrections about a person, newest first, with provenance (`author`, `event`, `run`); runs acting for or messaging that person recall them. Use it in People.
- (from runtime) Shared routines (decision 0062): `Workspace.routineUses(name:)` (where a routine is used, live version, whom each steward follows), `routineUpgrades(steward:)` (newer versions available, `pending` when proposed and gated), `upgradeRoutine(steward:name:)` for an Upgrade button (an adoption through the target's gate).

- (to cli-e2e, FYI, review 16 and 19) Connect appended to the demo seeder: `.prefer` steps
  (seven per-person preferences through `remember(_:steward:about:by:)`, decision 0061), a
  second triage sweep proposing `spot-duplicate-charges` version 2, and `.upgradeRoutine`,
  which promotes it in triage so refunds has an upgrade (decision 0062). Adapter profiles
  in `adapters.json` carry an optional `label` (the display name). The seed stamp changes.

## Log

- 2026-11-10: Busy demo and a live thread. `arya message` and `arya report` seed Sam's and
  Priya's conversations, hand-offs, and reports across three stewards; a working line shows a
  hand-off's run in progress; reviewer defects (a) to (e) fixed. (d) and (e) came from the
  old snapshot fixture (seeded report text and an extra approval); `people-thread` now renders
  the demo home itself, so reports come from `reportDigest` and counts from the workspace.
  Visual check (6938b70): `people-thread` and `people-thread-live` on the demo home show Sam's
  asks, the steward's replies, a correction, the weekly report, and hand-offs as tasks; the live
  state adds "Support inbox triage calling inbox.search… step 2" under a new hand-off. Moves (5)
  busy demo and (4) live feel; Needs you reads 6 in the rail and the status bar.

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
- 2026-11-10: M3.6 #7 Routines library: Go ▸ Routines (⇧⌘L), one row per routine across
  stewards (live version, stewards, pass rate, last run, runs per day); the inspector has each
  steward's version, the newest diff, history, and Use in steward… (`Workspace.adoptRoutine`,
  decision 0061). M3.6 #10 fan-out: the run inspector shows a crew run's host and delegates
  with status, step, duration, and outcome, ticking while it runs.
  Visual check: `routines-library` (demo's two versions diffed), `crew-fanout-live` (one done,
  two working, one refused).
- 2026-11-10: CLI `routine library`, `routine adopt NAME VERSION --from --into [--as]`, `run
  crew RUN` over new reads `Workspace.routineLibrary()` and `crew(run:)`; `shareRoutine` (new)
  returns `RoutineAdoption` (gate nil without a casebook); `adoptRoutine` keeps its gate result. Version pinning in the library
  inspector: "pinned <version>" per steward and a tertiary "Update to …" when another steward
  runs a newer live version. e2e steps 54-58 and the demo's shared routine (CEO unblock).
  Visual check: `routines-library` on the reseeded demo selects `spot-duplicate-charges`: both
  stewards "pinned be8641ab646d", 75% pass · 9 runs, history with Priya's adoption.
- 2026-11-10 (CEO review 16 addendum, 19, 20; runtime surfaces): Adapters show a display name
  from the profile's optional `label` (`Workspace.adapterLabels()`); the id stays in the
  tooltip. The inspector's Test connection is a plain button; the row Test stays quiet.
  People is a list on the left (two-line rows: role, counts, last contact, stewards) and the
  selected person on the right: messages per day for 14 days, their threads per steward, the
  conversation and composer, REMEMBERS ABOUT <name> (`personMemory(person:)`, decision 0061,
  with who said it and which steward keeps it), LEARNED FROM, and WAITING ON (their
  questions and the held actions they approve). Everyone opens on the person contacted
  most recently. Connections adds calls per day for 14 days, with adapters and recent calls
  in two columns. The Routines library is a split: rows on the left (name, live versions,
  stewards, pass rate, sparkline, an UPGRADE AVAILABLE pill), runs per day and recent
  changes under them, and the selected routine's script, newest diff and run history on the
  right. The inspector's Upgrade proposes the followed steward's version
  (`routineUpgrades()`, `upgradeRoutine(steward:name:by:)`, decision 0062) in place of the
  old Update to …. Routine text wraps to two lines instead of clipping (review 20). The demo
  seeds seven preferences and triage's version 2 of `spot-duplicate-charges`. New states:
  `people-memory` and `routines-upgrade`.
  Recent calls drop the connection column (the target names it; bare reads get it as a
  prefix). The composer puts Ask, Correct and Hand off above a full-width field.
  Visual check (empty share, window / main pane): people 67/59 → 47/39, people-memory 48/40,
  connections 51/44 → 46/39, connections-detail 51/45 → 42/30, routines-library 77/86 →
  49/43, routines-upgrade 49/43. Only connections-detail meets the 35% target. People and
  Routines end above the bottom of the window on this demo: nine people, two routines, nine
  runs. No text clips mid-phrase in these states. Message previews and inspector lines still
  end in an ellipsis.
- 2026-11-11 (CEO): `PeopleDirectory.displayName` calls app-views' `HumanText.actor`, so
  connections, governance, reports and person-note provenance name people the same as every
  other by-line, and the person at this home reads "you". Bare ids still read as names.
