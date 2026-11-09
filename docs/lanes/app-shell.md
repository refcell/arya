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
- [ ] Components: buttons, badges for run and approval states, list rows, cards, empty states,
  code and diff blocks, the effort selector.
- [ ] App entry: `@main` app, one window, menu commands, opening `$ARYA_HOME` (or a home chosen
  at launch) through the facade.
- [ ] Shell: left rail (stewards, their runs), header (steward name, state, effort selector),
  tab bar (Changes, Ledger, Memory, Routines, Rehearsals), main pane host for feature views.
- [ ] Approval queue entry point always visible with a pending count.
- [ ] Live updates: observe the facade's event stream and refresh on the main actor.
- [ ] `etc/app/Info.plist` and icon placeholder; `just app` and `just run-app` produce and open
  a working `Arya.app`.
- [ ] Preview fixtures: a stub workspace with sample stewards for development and screenshots.

## Decisions

- Tab order follows STYLE.md (normative): Stream, Changes, Ledger, Memory, Routines, Rehearsals.
- Color tokens are `AryaColorToken` cases with paper and ink hex values; `AryaColor.x` is a
  dynamic SwiftUI color. Contrast is computed and tested from the hex values (decision 0020).
- Type tokens are `AryaTextStyle` values in `AryaFont`; apply with `.aryaText(style, color)`.
  Text size scales through the `aryaTextScale` environment value.
- Fixed sizes from STYLE.md live in `AryaSize` so feature views never write literal sizes.

## Questions

- From memory: `AryaDesignTests` crashed intermittently (signal 6/11) when AppKit color and
  font tests ran in parallel; the two AppKit suites are now `@MainActor`. Keep new AppKit tests
  on the main actor.

## Log
