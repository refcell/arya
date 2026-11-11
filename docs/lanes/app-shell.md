# Lane: app-shell

Owns `Sources/AryaDesign`, `Sources/AryaApp/App`, `Sources/AryaApp/Shell`,
`Tests/AryaDesignTests`, `etc/app`, and `docs/STYLE.md`.

Goal: **a calm, native macOS window that makes stewards, runs, and approvals easy to watch.**
The design system from [STYLE.md](../STYLE.md) as tokens and components, the app entry point,
window, rail, header, tab bar, approval queue placement, the app bundle, and `just snapshot`.
Design: [ARCHITECTURE.md](../ARCHITECTURE.md#the-app), decision 0002.

## Backlog

**#1 item, before everything below (user feedback, 2026-11-09 night).** The user compared the overview, run, and
command palette snapshots against the visual target. Verdict: less than 60% of the look, and
not even remotely close to the feel. Green CI and reviewer scores are not the bar; the user
is. Fix these five first; this lane owns its share:
1. A run is a sparse log, not a work pane. Raw JSON dumped as INPUT; the right side is run metadata. Target: a split work pane, with the conversation on the left and live tools, diffs, logs and command output on the right, streaming as it happens.
2. Dead space everywhere. The bottom 40% of every screen is empty, the inspector is mostly blank, and the top padding is large. Density must come from real content, not wider margins.
3. Controls read as plain labels ("Edit charter...", "Pause", Low/Medium/High). Actions need clear, compact, keyboard-hinted affordances.
4. The feel is missing: no sense of an agent working live, no streaming, no motion or progress, no inline diffs, no keyboard-driven flow beyond the palette. It feels like a static report.
5. The content is thin: 3 stewards and a short plan. The demo home must look like a busy, real workspace.

M3 (start now against a stub `Workspace`; switch to the real one when runtime lands):
- [x] `AryaDesign` tokens: colors (light and dark), type scale, spacing, radii, from STYLE.md;
  tests that every token resolves in both appearances.
- [x] Components: buttons, badges for run and approval states, list rows, cards, empty states,
  code and diff blocks, the effort selector.
- [x] App entry: `@main` app, one window, menu commands, opening `$ARYA_HOME` (or a home chosen
  at launch) through the facade.
- [x] Shell: left rail (stewards, their runs), header (steward name, state, effort selector),
  tab bar (Changes, Ledger, Memory, Routines, Rehearsals), main pane host for feature views.
- [x] Approval queue entry point always visible with a pending count.
- [x] Live updates: observe the facade's event stream and refresh on the main actor.
- [x] `etc/app/Info.plist` and icon placeholder; `just app` and `just run-app` produce and open
  a working `Arya.app`.
- [x] Preview fixtures: a stub workspace with sample stewards for development and screenshots.

M3, extended (toward the end-to-end scenario and `just demo`):
- [x] Facade-backed `FeatureWorkspace` (`FacadeFeatureWorkspace`) so a real home feeds the
  feature views, not only preview mode.
- [x] Text size: View menu Bigger, Smaller, Actual Size (⌘+, ⌘−, ⌘0 style) driving
  `aryaTextScale`, persisted in user defaults.
- [x] Keyboard: arrow keys move through the rail in reading order (`RailOrder`).
- [x] Keyboard: Command-Return approves and Command-Delete denies the focused approval card
  (`ApprovalCard`, decision 0034; plain Return granted a demo approval on window activation).
- [x] `just screenshots`: render the preview shell offscreen to PNGs in both schemes for the
  README and for visual review.
- [x] `just app-preview` and a `--home PATH` launch argument so `just demo` can open the app on
  a seeded home.
- [x] Switch effort, steward state, and runs to facade calls as runtime lands them; delete the
  shell stub paths each replaces.
- [x] One preview source: the app has no preview mode; `just demo` seeds a real home,
  `just screenshots` renders it, and the shell's fake lives in tests (`FakeWorkspaceSource`).
- [x] README screenshot: `docs/assets/app.png` via `just readme-screenshot`.
- [x] Style-fidelity pass: every tab in both schemes against STYLE.md, section by section.
- [ ] Scheduler login-item toggle and a menu bar status item with the pending count.
- [x] Steward menu: Start Run (⇧⌘R), Pause, Resume through the facade.

M4:
- [x] Approval notifications (local `UserNotifications`) with Approve and Deny actions.
- [ ] Person-binding inbox entry in the rail (waits on runtime's M4 person bindings).

## Decisions

- Tab order follows STYLE.md (normative): Stream, Changes, Ledger, Memory, Routines, Rehearsals.
- Color tokens are `AryaColorToken` cases with paper and ink hex values; `AryaColor.x` is a
  dynamic SwiftUI color. Contrast is computed and tested from the hex values (decision 0020).
- Type tokens are `AryaTextStyle` values in `AryaFont`; apply with `.aryaText(style, color)`.
  Text size scales through the `aryaTextScale` environment value.
- Fixed sizes from STYLE.md live in `AryaSize` so feature views never write literal sizes.

- AryaDesign has no module dependencies, so it carries presentational enums (`AryaStatus`,
  `AryaPolicy`, `AryaEffort`); the app maps core types onto them.
- Components so far: button styles (`.aryaPrimary`, `.aryaSecondary`, `.aryaTertiary`),
  `StatusDot`, `StatusBadge`, `Chip`, `PolicyChip`, `CountLabel`, `RailRow`, `RailGroupLabel`,
  `StepRow`, `TableRowFrame`, `ApprovalCard`, `EmptyState`, `CodeBlock`, `DiffBlock`,
  `EffortSelector`, `TextTabBar`, `AryaTime` (relative and absolute times).
- Diffs stay monochrome; only the `+` and `-` marks use `positive` and `negative` text.

- The app reads the facade through `WorkspaceSource` (`Shell/WorkspaceSource.swift`);
  `Workspace` conforms, and `PreviewWorkspace` is the in-memory stub with invented sample data
  and a fixed clock. (Superseded: preview mode is gone; `FakeWorkspaceSource` is test-only.)
- Navigation contract for app-views: `StewardTab`, `Destination`, `NavigationState`
  (`Shell/Navigation.swift`); feature views take a `FeatureContext` (model, steward, run) and
  are wired in `Features/FeatureRegistry.swift`, which app-views owns from now on.
- `AppModel` refreshes on every ledger event from `events(from:)`; writes go through the
  source and the model refreshes afterwards. When the stream ends, `live` says why.
- `Tests/AryaAppTests` tests the `AryaApp` executable target; shell tests live there, and
  app-views adds its own files beside them.
- The rail is a custom view, not `NavigationSplitView`, because the system sidebar draws
  vibrancy, which STYLE.md forbids. The rail resizes by dragging the hairline (200–320 pt).
- Effort reads and writes go through the facade (`effort(for:)`, `setEffort(_:for:by:)`,
  decision 0026); the app passes its process environment to `Workspace.open` for adapters.
- Two seams coexist for now: the shell reads summaries through `WorkspaceSource`, and the
  feature views read events through app-views' `FeatureWorkspace`/`FeatureStore`. The shell
  passes the store in `FeatureContext.store`; real homes feed the
  feature views through `FacadeFeatureWorkspace`.
- The icon is drawn at bundle time by `etc/app/make-icon.swift` (AppKit, STYLE.md colors) and
  converted with `sips` and `iconutil`, so no binary asset is tracked.
- Screenshots draw `RootView` through `NSHostingView.cacheDisplay`, because `ImageRenderer`
  skips scroll views. With a feature store wired, the rail's approvals count comes from the
  same events as the queue (`StoreApprovalsRow`).
- Notifications announce approvals that became pending since the last refresh; the first load
  only primes, so opening the app never floods. They are enabled only when the app runs from
  its bundle; tests use a recording poster.
- Rail runs are labelled by start order ("run 14"), since run ids are long and opaque.
- `just publish` quotes its filter, so regex filters work (`'Arya(App|Design)Tests'`).

## Questions

- (from app-views) Dead space on the run screens (run-live-window 54%, run 47%): the work pane now fills to the composer, so most of what stays empty is the inspector below its facts (about 15% of the window) and the sidebar's bottom. Could the inspector hold the run's steps (`RunBrief.steps`, waterfall rows) or recent activity under its facts?

- (from app-views) Review #19: `HumanText` (Features/Support/HumanText.swift) is the one humanizer for Needs you: `HumanText.action(kind:target:params:)` ("Assign ISSUE-7 to Alex"), `name`, `sentence`, `verb`, `pastVerb`, `adapter`.

- (from app-views) Review #17: inspector STARTED should be a clock time ("14:02", `StreamStepText.clock` or `FeatureTime`), and DURATION should be `FeatureRunFacts.elapsedText(now:)`. Adapter ids anywhere in the shell: `AdapterName.display(_:named:)` (one helper; connect fills `named` from its catalog).

- (from app-views) Review #16: run titles in lists are now `RunTitle.parts(summary:dryRun:)` → `{title, isDryRun}`, and `StatusMapping.threadTitle` returns the title without the "Dry run" prefix. Please show `DryRunPill()` next to the title where `isDryRun` (rail ThreadRow, palette, breadcrumb, inspector); `EntityName.plain(_:)` / `EntityLabel(ref:)` turn refs like "person:alex" into names if any of yours show raw refs.

- (from app-views) Review #14 item 3: run titles need one function. `RunTitle.text(summary:dryRun:steps:)` (RunStreamModel.swift) gives "Dry run: would …" for a dry run. Please call it in `StatusMapping.threadTitle` (breadcrumb, sidebar, inspector) with `dryRun: store.runFacts[run]?.dryRun ?? false`; the stream and run header already use it. Done (app-shell): `AppModel.title(of:)`.

- (from app-views) Review #12: the run inspector's STEPS and PROPOSED still come from `InspectorView.RunFacts.lines`. `FeatureStore.runFacts[run]` (`FeatureRunFacts`, from workspace `runFacts(run:)`) now holds the counts, start, elapsed time and progress the run header uses. Please read it, so header and inspector agree.
- (from app-outcome) StewardPulse "Next wake"/"Running": please build state with `OutcomeState.build(serve: model.featureStore?.serve)`, format with `AryaTime.upcoming` ("due 10:19" when `state.serving == false`), and count running from `StatusBarLine.lines(live:...)`, so it matches NOW and the status bar.

- From memory: `AryaDesignTests` crashed intermittently (signal 6/11) when AppKit color and
  font tests ran in parallel; the two AppKit suites are now `@MainActor`. Keep new AppKit tests
  on the main actor.
- (from workspace) Effort is live (decision 0026): `Workspace.effort(for:) -> String` and
  `setEffort(_:for:by:)` (person defaults to `local`); `WorkspaceSource` can call them. Done.
- (from app-views) proposed: `FacadeFeatureWorkspace` forwards the facade calls that now exist: reads `routineContent`, `caseExpected` (decode `Data` as `FeatureJSON`), `replay(run:)` (map `ReplaySummary`), and writes `.correctCase` → `correct(steward:case:expected:note:casebook:)`, `.markReady` → `markReady(steward:)`, `.startRun` → `startRun(steward:input:)`, `.rehearse` → `rehearse(steward:casebook:)`.
  Done: `WorkspaceSource.record(_:)` maps every write; retracting memory has no facade call yet.
- (from app-views) the inbox is ready: point the rail's person-binding inbox entry at `FeatureRegistry.inbox(context)`, and forward `.answer(approval:text:)` in `FacadeFeatureWorkspace` as `approve(_:note:)` with the text as note.
- (from workspace) `changes(after:) -> AsyncThrowingStream<Int, Error>` yields the newest ledger seq with a newest-only buffer (one refresh per burst, other writers included); `lastSeq()` gives the starting point. Suggest it over `events(from: 1)` for refreshes.
- (from app-outcome) `FeatureRegistry.outcomeLine(context)` is the shared outcome line (KPI vs target, sparkline, status, one primary action); I placed it under `HeaderView` in `StewardPane` as an interim, please own its final spot. `StewardTab.overview` is now first and default, and selecting another steward opens it; please list `AryaFont.metric` (mono 28/32) and the Overview tab in STYLE.md, and add a `warning` (amber) color token for "at risk".
- (from app-outcome) the sidebar '+' can open the New steward sheet with `model.stewardSheet = NewStewardDraft()`; MainPane presents it and shows `FeatureRegistry.firstLaunch` when there are no stewards.
- (from app-views) proposed: while a run with a pending approval is shown, make the header's "Review 1 approval" quiet (the inline Approve is that screen's one accent); and the reviewer saw the first steward-row click ignored after viewing the queue, likely `navigation.destination` staying `.approvals` until a second select.
- (from app-outcome) one time rule per screen (CEO): relative under 24 h, clock time after. `OutcomeTime.short` (Features/Outcome) does `ThreadRow.shortTime` under 24 h, then `yesterday 14:02`, `Mon 14:02` within a week, else `9 Nov`; please move it into AryaDesign (for example `AryaTime.short`) and use it for threads too, and I will switch to it.
- (from app-outcome) FYI: I added New steward steps 2-5 to `SnapshotTests` (`new-steward-2…5.png`, a small additive loop after `new-steward`); `NewStewardSheet` takes a starting `step`. Move or reshape it as you like.
- (from app-views) proposed: `AryaTime.clock(_:seconds: true)` ("14:27:05"); the ledger needs seconds to order same-minute events, so it keeps its own HH:mm:ss clock until then. Also forwarded `event(seq:)` through `WorkspaceSource`/`FacadeFeatureWorkspace` (`eventDetail(seq:)`), and `LedgerView(selection:openRun:)` lets the ledger-inspector snapshot select an event.
- (from workspace) live: `retract(memory:reason:by:)`; in `WorkspaceSource.record` use `case .retractMemory(let note, let reason): _ = try await retract(memory: note, reason: reason.isEmpty ? nil : reason, by: person)`.
- (from app-views) FYI: the app no longer writes policy sentences (`PolicyText` deleted; `ApprovalSummary.policyText` and `change.text` via `FeatureStore.approvalTexts`). I passed the facade's sentence into `needs-you-autonomy` through `PreviewWorkspace(approvalTexts:)` in SnapshotTests; building that page on a real `Workspace` would be more faithful.
- (from app-outcome) the steward settings "Edit charter" button can call `FeatureRegistry.editCharter(model)`: it opens the New steward sheet prefilled from the live charter (via `model.stewardSheet`), ending in Propose change and landing on Improve. Also in Steward > Edit Charter… (⇧⌘E).
- (from workspace) live: `fleet() -> [FleetItem{steward, name, state, ready, metric, unit, current, target, status, pendingApprovals, needsYou, lastRun{id, title, status, time}, nextWake}]`, needs-you first; charter editing: `charterDraft(steward:) -> CharterDraft{version, draft}` then `proposeCharter(steward:draft:baseVersion:title:)` (a gated proposal; `StewardDraft.level` is the autonomy level).
- (from governance) live: `policySummary(steward:)` (tool allowlist per binding, each action kind with decision, risk, and approvers) for the inspector's policy section (decision 0044), and `ApprovalSummary.approvers` for "Needs person:alex" on approvals.
- (from connect) Added `Destination.connections(steward:)`, a Connections… button in Settings,
  and Go → Connections (Shift-Command-K); please add Connections to the command palette when it
  lands, and restyle freely.
- (from workspace) live: `serveStatus() -> ServeStatus{serving, servingHere, lastTick, stewards[{steward, name, state, intervalSeconds, nextWake}]}` for the status bar.
- (from governance) Landed myself: `StewardGovernanceSection` (tools and actions with decision, risk, approvers; approver rules; per-steward retention) after the Policy section in `InspectorView.stewardContent`, and `HomeGovernanceSection` (retention plan, encryption at rest) in `AppSettingsView` (new `governance:` parameter, window 460×400). Code in governance-owned `Features/Governance/`; move or restyle freely. Snapshot states `governance-inspector`, `governance-settings`, `governance-policy`.
- (from workspace) live: `runFacts(run:)` {status, started, ended, elapsedSeconds, decisions, toolCalls, actionsProposed/Applied/Drafted/Failed/Waiting, stepIndex, estimatedSteps, progress, dryRun}, `liveRuns()` (now with elapsedSeconds, estimatedSteps), and `stewardLive(steward:)` {running: RunFacts?, alsoRunning, schedule, intervalSeconds, nextWake, serving} share one cached tally: use only these for run counts, durations, progress, and NOW/RUNNING/SCHEDULE (CEO: one source per fact).
- (from workspace) one serving rule (CEO): `serveState() -> ServeState{serving, schedulerRunning, servingHere, drivenRuns, reason: scheduler|runs|off}`; serving = a scheduler holds the lock OR a running run's lease is held. `serveStatus().serving`/`.scheduler` and `stewardLive(steward:).serving` use it; the status bar and NOW must read only these. Also `verifyLedger().lines`: the ledger's plain-word report (headline, where, meaning, next step).
- (from workspace) dev overlay: `timings(limit:) -> [FacadeTiming{name, calls, totalMillis, meanMillis, maxMillis, lastMillis}]`, slowest single call first, for this process; wrap facade calls at one place in WorkspaceSource with `workspace.timed("fleet") { ... }`; the cache records `cache.fold` and `cache.rebuild` itself; `resetTimings()` clears.
- (from workspace) Run-count bars (portfolio RUNS 7D, inspector RUNS · 7 DAYS, fleet pulse): read `runHistory(steward:days:timeZone:)` (`days[].runs/failed/rehearsals`, `total`, `today`, `line`) instead of counting `runs()` in `StewardPulse.perDay`; it counts top-level live runs and keeps rehearsal case runs apart (on the seed, 40-126 rehearsals on one day flattened the other days' bars). Test: bars sum to the runs in those days. `runFacts.estimatedSteps` is now nil once a run ended (show `stepIndex` steps), and never below `stepIndex` while running.
- (from workspace) One step definition (CEO): a step is a thread row the user sees (tool call, proposed action incl. approval asks, message). `LiveStep.isVisible` marks them; `visibleSteps(run:)`, `runFacts.stepIndex`, `liveRuns().stepCount`, `LiveUpdate.stepCount` and `estimatedSteps` (median visible steps of the steward's last 5 runs of the same kind) all use it. Header, brief checklist, inspector and status bar should read these, not count `steps`.
- (from cli-e2e) Portfolio RUNS 7D still spikes on rehearsal days; read `runHistory` (e3c13075)
  there, as the overview inspector already does?
- (from runtime) Settings ▸ Access is ready (`Sources/AryaApp/Features/Access`, runtime-owned for M3.6 #13): please make Settings tabbed (General | Access) and host `AccessSettingsView(source: session.model?.access)` in the Access tab, sized `AccessSettingsView.windowSize` (640 × 560). Snapshot states `access`, `access-refusals`.
- (from workspace) Steps: tool calls in `visibleSteps`/`stepIndex` now follow the TOOLS tab's precedence (step records > proxy > adapter), so one call never counts twice; `LiveUpdate.steps[].isVisible` is marked the same way. While running, `estimatedSteps` ≥ `stepIndex + 1` ('4 of ~5'); nil once ended.

- (from runtime) For the full-window review I added a tiny Shell hook: `Destination.access` (`showAccess()`, Go ▸ Access, `InspectorFocus.access`, `MainPane` case, `RailOrder` nil), hosting `AccessSettingsView(source:, page: true)` between the sidebar and an Access inspector. Yours to restyle or move; the Settings-tab request above still stands if you prefer both.
## Log
- 2026-11-09: AryaDesign tokens and decision 0020 landed (40d3fbc).
- 2026-11-09: AryaDesign components and decision 0021 (`@AryaState`) landed (3234ede).
- 2026-11-09: window, rail, header, tabs, approvals entry, live updates, preview workspace
  (c1b00af). For app-views: `FeatureRegistry` now hosts `RunStreamView` and
  `ApprovalQueueView` through `FeatureContext.store`; it is yours to extend.
- 2026-11-09: facade-backed `FacadeFeatureWorkspace` for real homes (7abeedf).
- 2026-11-09: text size commands, `--home`, `just app-preview` (0ab37da).
- 2026-11-09: rail arrow keys, `just screenshots`, one approvals count (bdd54f6).
- 2026-11-09: effort through the facade; real homes show stewards (7f3044c).
- 2026-11-09: Return and Escape on focused approval cards (5b52dba).
- 2026-11-09: approval notifications with Approve and Deny actions (b0260e4).
- 2026-11-09: every steward tab routed to app-views' views; screenshots per tab (78c9c17).
- 2026-11-09: Steward menu (Start Run, Pause, Resume) through the facade (8258cb7).
- 2026-11-09: `just publish` quotes its filter (6406b7f).
- 2026-11-09: style pass on the demo home, every tab, both schemes. Shell fixes: rail runs read
  "run 14" instead of raw ids; a wide feature view no longer widens the window and clips the
  rail (main pane takes `minWidth: 0` and clips). Feature-view findings sent to app-views.
- 2026-11-09: feature writes and reads reach real homes: proposals, corrections, ready,
  rehearse, start run, routine bodies, expected results, replay (app-views' request).
- 2026-11-09: approval cards answer only Command-Return and Command-Delete (decision 0034).
- 2026-11-09: decision 0036, clean single-canvas workspace: STYLE.md rewritten; tokens moved to
  one dark canvas (`#0C0C0D`), `raised` for code only, sans plus mono type (no serif), 4 pt grid;
  the app opens dark (View > Appearance offers Light); approval block unboxed; `ThreadRow`,
  `Sparkline`, `OutcomeLine`, `InlineError` added.
- Visual check (tokens): one canvas across sidebar and page, no serif, approval unboxed with an
  orange label and one orange button. Still failing: gray title bar with a window title (rule 1),
  effort control in a header (rule 3), six tabs (rule 4), "run 18" thread titles, event id under
  Decision, duplicated summary, "action" and "auto" labels (app-views). Next push fixes chrome.
- 2026-11-09: chrome: hidden title bar with no title text, one canvas for sidebar, page, and
  inspector, hairline splits; sidebar shows the `arya` wordmark, "Needs you N" (hidden at zero),
  stewards, and runs as threads titled by summary; steward page has no header band, a sans title,
  one primary action, and four tabs (Overview, Improve, Knowledge, Ledger); effort, pause, home,
  and appearance moved to the settings inspector (gear, Option-Command-I); the window-wide error
  banner became an inline, dismissible error under the title.
- Visual check (chrome, `just app` on the demo home): R1 pass, traffic lights on the canvas and
  no strip; R2 pass, one canvas and hairlines only; R4 pass, four tabs and summary-titled
  threads; R5 pass, sans title and mono threads. R3: the header's review link is quiet on
  Overview so the inline Approve is the one orange element. Remaining in the Overview body
  (app-views): boxed tool cards, `auto` chips and "Ran", the charter status line, and the
  manual-run field shown inline.
- 2026-11-09: chrome, one canvas, summary threads, four tabs, inspector, and a run page that
  shows only the transcript under a breadcrumb landed (a0d8491). Decision 0035 became 0036.
- 2026-11-09: decision 0038, Visual check = `just snapshot` PNGs (offscreen, no window).
  `ScreenshotTests` became `SnapshotTests`; `just screenshots` became `just snapshot`.
- Visual check (`just snapshot`, 9 states, dark and light): R1 pass, no title band; R2 pass, one
  canvas with hairlines; R3 pass, the duplicate header "Review" button is gone (the outcome line
  owns the one primary action) and Appearance is quiet text, not a blue segmented control; R4
  pass, four tabs, threads titled by summary, a run shows only its transcript; R5 pass, sans
  only. Open for app-views: ledger columns truncate (`run.a…event`, `1h…go`).
- 2026-11-09: merged tabs scroll as one column, '+' by the wordmark, threads in sans up to two
  lines, `AryaTime.label` (relative under 24 h, clock after), `accentFill` (one orange in both
  schemes), and `just snapshot` clears old PNGs and adds `window` (chrome), `ledger`, `settings`.
- Visual check (`just snapshot`, 11 states): R1 pass in `window` (traffic lights on the canvas,
  no band); R2 pass; R3 pass, one orange action per screen in dark and light; R4 pass, Improve
  shows all 8 cases and Knowledge no longer clips, thread titles wrap to two lines; R5 pass.
  Pending app-views: the ledger event inspector for a selected row.
- 2026-11-09: `ChoiceRow` (check mark, no box) for effort and appearance in settings; threads one
  line, two when selected, full title on hover.
- Visual check (`just snapshot` settings, run): Effort labeled once with a visible selection,
  Appearance shows Dark checked; five threads take about 120 pt; R1-R5 pass.
- 2026-11-09: snapshot state `needs-you-autonomy`: a `suggest` steward's low-risk label held by
  autonomy (`autonomy:suggest:low`), not a rule.
- Visual check (`just snapshot` needs-you-autonomy): one orange action, the held action, its why
  and "held by autonomy suggest low · risk low"; R1-R5 pass. Wording of that line is app-views'.
- 2026-11-09: Knowledge tab (handed over from app-views) rebuilt on `knowledge(steward:)` as one
  column: notes as a sentence plus one muted provenance line, Retract on hover and in the context
  menu, ids only behind the context menu; routines as rows (mono name, one status word) that
  expand to their versions. Old Memory and Routines views removed. Ledger row selection lives in
  navigation (`ledgerEvent`) and closes settings; `just snapshot` reseeds the demo home when its
  seed inputs change (`etc/scripts/demo-current.sh`) and adds `ledger-inspector`;
  `AryaTime.clock(_:seconds:)`.
- Visual check (`just snapshot` knowledge, ledger-inspector, dark and light): Knowledge R1-R5 pass,
  no chips, pills, buttons, or ids; ledger shows the event inspector on reseeded, dated data.
- 2026-11-09: autonomy holds read as the workspace's sentence (`PolicyText.autonomy`), never the
  raw `autonomy:<level>:<risk>` token.
- Visual check (`just snapshot` needs-you-autonomy, current main): "This steward only suggests
  changes, so a person approves each action."; R1-R5 pass.
- (to app-views) `PolicyText` gained the autonomy branch in `RunStreamModel.swift`; unknown
  reasons now read "The steward's policy holds this action for a person." instead of the token.
- 2026-11-09: one time rule. `AryaTime.label` is relative under 24 h, then "Nov 8", in every view.
  `FeatureTime` delegates to it, the stream gutter uses `AryaTime.clock`, and a test fails on any
  date formatter in `Sources/AryaApp`. Knowledge shows "waiting" in the muted tone, reads
  `case-0006`, and Retract calls workspace's `retract(memory:)`. The sidebar shows steward health
  (`needsYou`, `onTrack`, `offTrack`, `paused` with a muted word) and the selected steward's
  metric against its target; new snapshot state `stewards`.
- Visual check (`just snapshot`, reseeded 3-steward demo): MSG-203 reads "Nov 8" on Overview,
  sidebar, and Needs you; the plan line reads "Changed Nov 8". The sidebar shows paused muted,
  needs-you orange, and `0.84 / 0.90` on the selected row. R1-R5 pass.
- 2026-11-09: one time wording. Rows say `now`, `12m`, `3h`, `Nov 8`, or `Nov 8, 2025`; only
  sentences say "ago" (`FeatureTime.phrase`, `AryaTime.label(style: .long)`). Off-track dot is
  `negative`; the paused dot is a hollow ring beside the muted word.
- Visual check (`just snapshot` stewards, needs-you): paused shows a hollow ring and the word;
  needs-you rows are orange; meta reads `9m` and `Nov 8` with no "ago"; R1-R5 pass.
- 2026-11-09 (check #15): sidebar dot = attention only (orange with approvals, else neutral, ring
  when paused); health = text (`StatusMapping.SidebarRow`): behind target shows the value in red
  mono on every row, the selected on-track steward shows it muted, paused shows the word. Sorted
  needs you, behind, on track, paused; VoiceOver reads "Refund follow-up, needs you, behind
  target, 0.84 of 0.90".
- Visual check (`just snapshot` stewards, overview-light): Refund follow-up (red 0.84) first,
  Support inbox triage (muted 0.96 when selected), Weekly queue digest ring plus paused last;
  names untruncated at 240 pt; R1-R5 pass.
- 2026-11-09 (M3.5): settings has an Edit charter… button (`FeatureRegistry.editCharter`). The
  Details disclosure's Next wake fact became a Schedule line, "Next run 14:00 · last 5 ✓✓✓✕✓"
  (`OutcomeSchedule`, `AryaTime.upcoming`, `TriggerStrip`). It is derived from the ledger
  until the facade exposes runtime's `schedule()`. New snapshot state `details`. The sidebar
  still waits on workspace's `fleet()`.
- Visual check (`just snapshot` details, settings): Schedule reads "Next run 19:16 · last 5"
  with five positive checks; Edit charter… is a quiet button under the steward id; R1-R5 pass.
- 2026-11-09 (R6): dense type scale in `AryaFont`: title 15, metric 16, body 12/16, new prose
  12/17.5, mono 11, monoSmall 10.5, label 9.5, caption 11/15.
- Visual check (`just snapshot` overview): every view picks up the smaller scale; feature list
  rows still carry their own vertical padding (R7 next); R1-R5 pass.
- 2026-11-09 (R7, decision 0044): three zones. The stream fills between the sidebar (232) and
  a persistent inspector (340) that follows the selection: event payload and hash, run facts
  and cost, else steward context (plan, schedule, policy, connections, people, effort) with
  Settings last. The settings pane grew into it; no raw steward id. Features drop the
  `readingWidth` cap on lists and threads, and section gaps are `s4` at most.
- Visual check (`just snapshot` overview-with-inspector, run, ledger-inspector, needs-you):
  lists and threads fill the stream; the inspector shows steward context, run facts, and the
  event payload in one place; R1-R5 pass.
- 2026-11-09 (R8-R9): command palette (Command-K, `CommandCatalog` plus
  `FeatureRegistry.commands`, fuzzy `PaletteSearch`, keycaps, ↑/↓/↩/Esc) and the 22 pt status
  bar (`StatusBarLine`: scheduler "—" until `serveStatus()`, next run, fleet, waiting, ledger verified, today's spend). Shortcuts:
  ⌘K, ⌘N new steward, ⌘\ sidebar, ⌥⌘I inspector, ⌘0-4. Needs you's inspector shows an interim
  approval summary (app-views' `approvalInspector` swaps in when it lands); the Plan duplicate
  is gone; home and appearance
  moved into the Settings window (gear, Command-comma). RunFacts pluralize and show "—" for
  unknown duration and cost.
- Visual check (`just snapshot` command-palette, needs-you, overview, app-settings): the
  palette lists steward, go, and steward-jump commands with keycaps; the status bar shows on
  every state; Needs you's inspector shows the approval's steward, run, policy, and risk; R1-R5
  pass.
- 2026-11-09 (VC21, #15): Portfolio ("All stewards" row, ⌘9, palette): one table of every
  steward (metric vs target with sparkline, state, needs you, last run, next), sorted by need.
  The inspector mounts app-views' `approvalInspector` (Needs you selection bound to
  `navigation.approval`); connect's selected-connection focus stays as they shipped it. Status bar: waiting
  in ink with a dot, "serving" / "scheduler stopped" from the home's `scheduler.lock`, "spend —
  today" when unknown. RunFacts take the run header's duration, cost, and tokens. Palette
  keycaps ⌥⌘P pause, ⌥⌘T rehearse, ⌃1-9 stewards, Approve/Deny selected (no approve for high
  risk); Settings window at its own size with a Text size choice row.
- Visual check (`just snapshot` portfolio, run, needs-you, app-settings): portfolio rows sort by
  need with red behind-target metrics; run inspector reads 14 ms like the header; status bar
  reads scheduler stopped and • 4 waiting on you; R1-R5 pass.
- 2026-11-09 Paused for the night (user order) after this commit. Next: Portfolio's Next column
  clips beside the inspector (give the table min widths or let Outcome flex less); Templates
  (#16) as step 0 of New steward; register app-views' and app-outcome's commands; the visual
  feel gap is tomorrow's top priority.
- 2026-11-10 Resumed. Look-and-feel day (points 2, 3, 4). Control set in AryaDesign: 24 pt
  buttons with hairline, hover and pressed fills and an optional keycap; `AryaIconButton`;
  `AryaSegmented` (ChoiceRow, EffortSelector, New steward choices, charter kinds); `AryaToolbar`.
  Bare-text actions became buttons (Show all, Add person, Open child run, Close). Motion:
  `AryaLiveDot`, `AryaSpinner`, `AryaProgressBar`, `aryaArrival`, inspector and palette
  transitions, a status bar ticker of the newest event and "<steward> running · step N". Pane
  headers moved into the title-bar band (12 pt top; the sidebar keeps 40 pt for the traffic
  lights). Inspector pulse: steward (metric chart, next wake countdown, cost today, running,
  7-day run bars, waiting on you, recent decisions) and fleet for All stewards (on track,
  behind, paused, waiting, runs and cost today, top movers). Portfolio columns fit.
- Visual check (`just snapshot` overview-live, portfolio-live, run, new-steward-2): moves (2)
  less dead space — header band 12 pt, inspector full on steward and fleet; (3) controls —
  boxed buttons with keycaps, segmented effort; (4) live — green live dots in the sidebar and
  status bar, running line and ticker. Portfolio no longer clips.
- 2026-11-10 Snapshot settle fix (CEO, urgent): motion freezes in snapshot and test processes
  (`AryaMotion.frozenByProcess`: any `ARYA_SNAPSHOT*` variable or an `.xctest` bundle). The
  live dot, spinner, and progress bar draw one still frame, the status bar skips its 1 s
  timeline, arrival washes hold, and the snapshot render disables animations. MotionTests
  bounds a live root render. Live runs: workspace `liveRuns()` feeds "<steward> running · step
  N · 4.0 s" (seconds tick live) and "step N" on the sidebar row. Needs you is two panes
  (reassigned to app-shell): queue (risk dot, sentence, steward, kind and target, age) and the
  full approval (app-views' InlineApproval with A/D/C keycaps and Correct, ApprovalInspector's
  facts without the repeated policy, approvers, the run's last six steps); the shell inspector
  shows the approval's steward pulse. j/k selection animates.
- Visual check (`just snapshot`, settled in 177 s under load 32: needs-you, overview-live):
  moves (2) — Needs you fills both panes; (3) Approve/Deny/Correct carry keycaps; (4) the
  status bar reads "running · step 1 · 11.0 s", sidebar rows "step 1" with live dots.
- 2026-11-10 Review #10 and VC26: scheduler cell reads "serving" while runs are live; status
  bar counts never truncate (the ticker gives way first); Needs you rows lead with a humanized
  "Reply inbox:ORDER-1043" that wraps instead of cutting ids, then steward and why;
  `ActionWords` humanizes kinds in one place (follow_up reads follow-up); the pulse lists
  waiting targets; keycaps no longer squeeze to empty; every "More" menu is a secondary
  button (`aryaMenuButton`); the inspector narrows to 280 pt beside a run; AryaProgressBar is
  ink (green when finished well), never orange. Portfolio: Runs 7d bars, Cost today, a
  running state with live dot; the metric column shows value / target with the name in help.
- Visual check (`just snapshot` needs-you, run, portfolio-live, overview-live): moves (2) and
  (3) — no duplicate rows, menus boxed, run pane wider; (4) status bar "serving · running ·
  step 1 · 11.3 s".
- 2026-11-10 (review 11 and CEO point 5): one source for "running": workspace `liveRuns()`
  via `AppModel.liveLines` feeds the rail, status bar, inspector pulse, and portfolio; the
  ledger-status fallback is gone and the snapshot's fake running runs fixture is removed (the
  snapshot home holds a real leased run). Test: every surface agrees on who is running.
  Sidebar grouped by department from workspace `portfolio()` (fold rows with count, waiting,
  behind, live dot; flat when no departments). Portfolio grouped by department (fold headers
  ordered by need, ties by most waiting), counts in the subtitle, short relative Last run, and
  a Fleet activity stream under the table. Templates (#16): step 0 of New steward lists the
  workspace templates as dense rows (name, outcome, department, metric and target, policy)
  plus Blank; picking one prefills every step. `just snapshot <state>...` renders only the
  named states (load rule).
- Visual check (`just snapshot` portfolio, portfolio-live, overview-live, sidebar-folded,
  new-steward): moves (2) portfolio no longer 70% empty, (4) one running steward everywhere,
  (5) the 11-steward fleet grouped by department in rail and portfolio.
- 2026-11-10 (CEO, one source per fact): fixture removal published alone (f489c020). On
  workspace ef524307/7e6a22fd: `LiveLine` carries `liveRuns().elapsedSeconds` (ticking from
  when it was read) and `estimatedSteps` ("step 3 of ~7"); the scheduler cell reads only
  `serveState().reason`; the pulse's running count reads `stewardLive`; the verified cell's
  tooltip is `verifyLedger().lines`. Merged with app-outcome's `serve:` pulse parameter and
  the upstream state filter (kept the lazy one: unlisted states never render).
- 2026-11-10: FeatureWorkspace.swift split by lane (CEO): core reads and writes stay there;
  `FeatureRunReads` (+Run, app-views), `FeatureOutcomeReads` (+Outcome, app-outcome),
  `FeatureConnectReads` (+Connect, connect), each with its types and defaults; the composite
  protocol inherits all three, so conformers are unchanged. Told the lanes under Questions.
- 2026-11-10 (review 14): every snapshot state renders under a 60 s watchdog
  (`SnapshotWatchdog`): a hang names the state, saves a 3 s stack sample to
  `.build/snapshots/hang-<state>.txt`, and exits; overview-live's setup has its own guard. The
  reported overview-live hang did not reproduce at HEAD (filtered run 33 s, full state 110 s).
  One behind rule, `StatusMapping.isBehind` (active and workspace `fleet()` says
  `off_track`), feeds the status bar, fleet pulse, steward pulse, portfolio, and rail: all read
  5 behind on the busy home (the paused digest no longer counts). The run inspector's Duration,
  Steps, and Proposed read `FeatureRunFacts` (workspace `runFacts`). Fleet activity shows at
  most two lines in a row per steward.
- Visual check (`just snapshot` portfolio, portfolio-live, overview-live, run-live): moves (4)
  one behind count everywhere, (2) fleet activity across stewards.
- Run titles take the dry-run prefix from workspace `runFacts.dryRun` (`AppModel.title(of:)`
  over `StatusMapping.threadTitle(dryRun:)`, using app-views' `RunTitle.text`) in the
  rail, breadcrumb, inspector, and palette.
  `AppModel.preloadRunFacts` loads the shown runs' facts on every refresh, and the snapshot
  test preloads the runs its pages open, so offscreen renders show the facade's numbers.
- Visual check (`just snapshot` run, run-approval, overview): moves (4) the same title and
  step tally in breadcrumb, rail, inspector, and run header.
- 2026-11-10 snapshot hang root cause (mine): offscreen renders start `.task`s, so every
  RootView render began `watch()` and `observe()`, and every live RunStreamView began an
  `observeRun` loop. None of them ended in the snapshot process, and each reloaded the
  workspace on every event of the leased live run, so about 80 renders stalled the late states
  (people-thread-live, overview-live). These loops now return when `AryaMotion.frozenByProcess`.
  `SnapshotProgress` is one rolling 60 s watchdog over every state's setup and render, plus the
  per-render one. Filtered-out states skip their setup. overview-live gets a fresh model.
  Decision: the other pages share one model; it is read-only now, and each page resets
  navigation. A fresh model per page would cost about 80 workspace opens and break the pages
  that set state first (folded departments, palette, credentials).
- Visual check (full `just snapshot`, 112 PNGs, 243 s, no hang sample): moves (4), a live run
  no longer freezes the review.
- One elapsed format: the inspector's own `RunFacts.duration` is gone; the status bar, NOW, and
  the inspector all use `FeatureTime.duration`, which now reads "1h 12m" past an hour.
- Review 16: the inspector's Duration and the status bar's clock use
  `FeatureRunFacts.elapsedText` (whole seconds while running). Finished runs read "34 steps",
  never "of ~". Rail run rows show a `TagPill` "DRY RUN" before the plain title (`ThreadRow`
  `badge:`). The breadcrumb and inspector keep `RunTitle.text`.
- Visual check (`just snapshot` run, run-live): moves (3) a real pill control, (4) one clock.
- Review 16 addendum: the snapshot tool reports each state's empty share (`SnapshotSpace`:
  48 px blocks with no content, printed and kept in `.build/snapshots/empty.tsv`). Mine:
  portfolio and portfolio-live 46% -> 35-36% (two-column fleet activity, fleet inspector adds
  By department and Oldest waiting), needs-you 56%, overview 40%, knowledge 56%,
  command-palette and sidebar-folded about 40-50%, new-steward 85% (sheet page). Needs you rows
  give the steward name its own line, never clipped, and cut the reason at a word
  (`AryaTrim.words`), with the full reason in a tooltip.
- Visual check (`just snapshot` portfolio, portfolio-live, needs-you): moves (2) dead space and
  (3) no mid-word clipping.
- Review 19/20: fleet activity sorts one list strictly by time (stewards interleave only
  within a minute) and splits it down then across (`FleetActivity.columns`, tested over the
  rendered order). Needs you and the inspector say actions as sentences with names
  (`ActionWords.sentence`, `ActionWords.humanize` over app-views' `EntityName`): "Send an email
  to LEAD-1095", "Wants to send an email to LEAD-1095." The dead-space method is in STYLE.md
  ("Dead space") and every full state is pinned to 1400 x 1000 pt; run-short moved to it. Now:
  overview 45%, portfolio-live 51%, needs-you 65%.
- Visual check (`just snapshot` portfolio-live, needs-you, overview): moves (2), and the empty
  share is measured instead of judged.
- Review 21: every runs bar reads workspace `runHistory` (portfolio RUNS 7D, the steward
  pulse with its `line`, fleet RUNS · 7 DAYS and runs today); `StewardPulse.perDay` is gone.
  Needs you rows use line 2 for context ("Lead follow-up · demo request, wants pricing ·
  waiting 2h"), never the action again. The detail pane has two columns (request and run;
  policy, approvers, the steward's other requests). Recent decisions show under the queue.
  Card reasons say "Wants to remind about invoice INV-1066". Person connections read "Maya ·
  owner". Governance's policy line says "Acts alone on medium risk". Dead-space target 30%.
- Visual check (needs-you, portfolio-live, overview, run-approval): moves (2) no dead space,
  needs-you 65 → 58, portfolio-live 51 → 50, overview 45 → 43; (3) real controls, approval
  buttons wrap and never clip. Seven daily bars in portfolio RUNS 7D. The snapshot watchdog
  stretches 60 s by load per core, after a false stop at load 190.
- Published 65317d48 (review 21 items, PortfolioRow typed lets, watchdog capped at 600 s).
  The run inspector lists the run's steps (up to 20, clock in the gutter) under its facts, as
  app-views asked; `NeedsYouRunSteps` takes a title and a limit.
- Visual check (run): moves (2) no dead space, the inspector column reads as the run; run 46.
- Published f8f59656 (run steps in the inspector). Review 26: the Needs you run link wrapped
  to two lines and cut at a word ("Ran spot-duplicate-charges on ORDER-1218."); the button
  label no-truncate rule had clipped it with no ellipsis.
- Visual check (needs-you): moves (3) real controls, the run link reads whole; needs-you 58.
- Review 28: the run inspector no longer repeats the thread's steps. Under the facts it shows
  what the thread lacks (`RunContext`): usage (tokens and cost), the systems touched with
  targets, the policy behind each action (ran on its own or asked a person, and the rule),
  follow-up check status, and related runs on the same targets. Needs you lists the steward's
  recent runs in the inspector and the whole run in the detail: needs-you 58 → 52.
- Visual check (run, run-approval, needs-you): moves (2) no dead space; run 44, run-approval 47.
- The sidebar ends with a folding Activity feed on every screen: the fleet's latest 8 events
  (time, steward, what; a failed run in red) from `FleetActivity.lines`, one click to the
  steward. Its fold is kept with the department folds under the key "Activity".
- Visual check (needs-you, overview, portfolio-live): moves (2) no dead space and (4) a live
  feel; needs-you 52 → 49, portfolio-live 50 → 48, overview 44.
- VC41/VC42: Needs you shows names, not ids (the card title says "Update commitment CMT-1060",
  "Earlier on CMT-1060"). Run titles never fall back to the trigger kind: the summary, else the
  workspace title (the input's first line), else "Untitled run". The run inspector always
  shows Usage, Touched, Policy, Follow-up checks and Related runs, with a dash while a live
  run has none, and names tools in people's words ("Search the inbox"). The sidebar Activity
  feed names the action ("labeled MSG-140", "asked to send an email to LEAD-1002"), folds
  repeats ("×5"), uses one-line rows (6 rows), and hides on All stewards, which has its own
  Fleet activity.
- Raw-id gate (STYLE.md "Raw ids"): the snapshot run reads every dark state's text with the
  system text recognizer (offscreen hosting views build no accessibility tree) and fails a
  state showing `person:`, `st_x`, `kind:ID-1` or `_snake_`. Metric names are allowed. The
  21 states that still show ids are in `etc/app/rawtext-pending.txt` with their lane:
  app-outcome (overview Recent "reply inbox:MSG-140", memory "person:lee"), app-views
  (run-approval input, crew refusal, charter editor), connect (connections, reports, people
  thread), workspace (routines "by st_triage"). "the cfo" vs "the CFO" is seed text (cli-e2e).
- Visual check (needs-you, overview, portfolio-live, new-steward): moves (2) and (4);
  empty.tsv: needs-you 51, overview 40, portfolio-live 51, new-steward 88.
- 2026-11-11 VC44 / review #31: the raw-id gate is strict. Any raw id in any state (the
  governance suite too) fails `just snapshot`. `etc/app/rawtext-pending.txt` excuses a state
  only with `<state> <lane> <YYYY-MM-DD> <reason>`, and a test rejects other lines. The full
  run found 4 after the cleanup, now listed with owners: run-approval and governance-run
  (app-views: "person:sam hands this to you"), governance-run-controls (governance: "label
  inbox:MSG-140 → unlabel"), people-thread-live (connect: "reply inbox:MSG-140").
  The run inspector hides an empty section (reverses the dashes), shows Usage only when known,
  and fills its lower half with the steward it serves: metric vs target, runs over 7 days,
  waiting, recent decisions, recent runs. People counts one identity per person
  ("person:sam" = "sam"). Activity rows wrap to 2 lines and never cut the action (5 rows). The
  Needs you runs line wraps under its label instead of clipping "1 fai…".
- Visual check (run, run-approval, overview, needs-you): moves (2) and (4); empty.tsv: run 32,
  run-approval 36, overview 40, needs-you 52.
- 2026-11-11 VC45: the run inspector's Cost reads the workspace's figure
  (`FeatureRunFacts.costMicros`), "$0.04 so far" while running, the same as the run header;
  Usage falls back to that cost while the ledger has no tokens yet. Test
  `inspectorCostIsTheHeadersCostSoFar`.
- Visual check (run, run-approval, overview-live): moves (4); empty.tsv: run 33, run-approval
  36, overview-live 45.
