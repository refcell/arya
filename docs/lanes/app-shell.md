# Lane: app-shell

Owns `Sources/AryaDesign`, `Sources/AryaApp/App`, `Sources/AryaApp/Shell`,
`Tests/AryaDesignTests`, `etc/app`, and `docs/STYLE.md`.

Goal: **a calm, native macOS window that makes stewards, runs, and approvals easy to watch.**
The design system from [STYLE.md](../STYLE.md) as tokens and components, the app entry point,
window, rail, header, tab bar, approval queue placement, the app bundle, and `just snapshot`.
Design: [ARCHITECTURE.md](../ARCHITECTURE.md#the-app), decision 0002.

## Backlog

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
