# Lane: app-shell

Owns `Sources/AryaDesign`, `Sources/AryaApp/App`, `Sources/AryaApp/Shell`,
`Tests/AryaDesignTests`, `etc/app`, and `docs/STYLE.md`.

Goal: **a calm, native macOS window that makes stewards, runs, and approvals easy to watch.**
The design system from [STYLE.md](../STYLE.md) as tokens and components, the app entry point,
window, rail, header, tab bar, approval queue placement, and the bundle that `just app` builds.
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
  and a fixed clock. Launch with `--preview` or `ARYA_PREVIEW=1` to use it.
- Navigation contract for app-views: `StewardTab`, `Destination`, `NavigationState`
  (`Shell/Navigation.swift`); feature views take a `FeatureContext` (model, steward, run) and
  are wired in `Features/FeatureRegistry.swift`, which app-views owns from now on.
- `AppModel` refreshes on every ledger event from `events(from:)`; writes go through the
  source and the model refreshes afterwards. When the stream ends, `live` says why.
- `Tests/AryaAppTests` tests the `AryaApp` executable target; shell tests live there, and
  app-views adds its own files beside them.
- The rail is a custom view, not `NavigationSplitView`, because the system sidebar draws
  vibrancy, which STYLE.md forbids. The rail resizes by dragging the hairline (200–320 pt).
- Effort has no facade read or write yet. The header shows `medium` for real homes and
  `setEffort` reports "cannot do that yet"; switch to the facade call once runtime adds it
  (noted in runtime's Questions).
- Two seams coexist for now: the shell reads summaries through `WorkspaceSource`, and the
  feature views read events through app-views' `FeatureWorkspace`/`FeatureStore`. The shell
  passes the store in `FeatureContext.store`; preview mode wires app-views' `PreviewWorkspace`
  next to `ShellPreviewWorkspace` (same `st_triage` run ids). Next: a facade-backed
  `FeatureWorkspace` so real homes feed the feature views too.
- The icon is drawn at bundle time by `etc/app/make-icon.swift` (AppKit, STYLE.md colors) and
  converted with `sips` and `iconutil`, so no binary asset is tracked.

## Questions

- From memory: `AryaDesignTests` crashed intermittently (signal 6/11) when AppKit color and
  font tests ran in parallel; the two AppKit suites are now `@MainActor`. Keep new AppKit tests
  on the main actor.

## Log
- 2026-11-09: AryaDesign tokens and decision 0020 landed (40d3fbc).
- 2026-11-09: AryaDesign components and decision 0021 (`@AryaState`) landed (3234ede).
- 2026-11-09: window, rail, header, tabs, approvals entry, live updates, preview workspace
  (c1b00af). For app-views: `FeatureRegistry` now hosts `RunStreamView` and
  `ApprovalQueueView` through `FeatureContext.store`; it is yours to extend.
