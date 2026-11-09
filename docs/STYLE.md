# Style guide

arya should read like a well-made technical book: calm, editorial, and exact. Light surfaces are
warm paper and dark surfaces are warm near-black ink. Hierarchy comes from type, space, and thin
rules, not from shadows or color. One warm amber accent marks the few things that need a
person's attention.

This guide is normative. The macOS app (macOS 14+, SwiftUI) follows it exactly. Every value here
exists as a token in `Sources/AryaDesign`, and feature views use tokens only: no literal colors,
font sizes, or paddings outside that module.

## Principles

1. **Type carries hierarchy.** A serif sets display headings, the system sans sets interface
   text, and a monospace sets anything a machine wrote or reads: ids, hashes, commands, code,
   paths, and numbers in tables.
2. **Rules, not shadows.** Regions are separated by 1 px hairlines. No drop shadows, gradients,
   blur, vibrancy, glass, or glow. Corners are small.
3. **Quiet by default, loud on purpose.** The palette is monochrome. The accent appears only on
   the primary action in view, pending approvals, the `ask` policy, and the live-run indicator.
   If two things on screen are accented, one of them is wrong.
4. **Space before boxes.** Prefer whitespace to containers. Never nest cards. A pane has at most
   one filled panel.
5. **Words before icons.** Actions are labelled with verbs. SF Symbols may appear at 12–14 pt as
   secondary cues, never alone on a primary action.
6. **Show the work.** A run is a readable record. Steps, tool calls, crew delegations, and
   decisions appear in order, with ids and times available but never shouting.

## Color

Two schemes: **paper** (light) and **ink** (dark). Names are semantic; code uses the token, never
the hex. Both schemes follow the system appearance setting.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `canvas` | `#F6F1E7` | `#141311` | window and main-pane background |
| `surface` | `#FBF8F2` | `#1B1A17` | rail, inspector, popovers |
| `sunken` | `#EFE8DA` | `#100F0D` | code blocks, text fields |
| `selection` | `#ECE5D7` | `#25231F` | selected rail row, selected table row |
| `ink` | `#1D1B17` | `#ECE6DA` | primary text, chart lines, selected tab and segment |
| `inkMuted` | `#4F4A3E` | `#B5AE9F` | secondary text, rationale, unselected tabs |
| `inkFaint` | `#6B6557` | `#918B7F` | tertiary text: timestamps, sequence numbers, placeholders |
| `rule` | `#DDD4C2` | `#2B2925` | hairlines, chip and table borders |
| `ruleStrong` | `#C7BCA6` | `#3A3731` | secondary-button border, table header rule, segment borders |
| `accent` | `#B13B0B` | `#F08A4B` | primary button fill, approvals count, `ask` chip, live dot, focus ring |
| `accentInk` | `#FFFFFF` | `#1A0F08` | text and symbols on an `accent` fill |
| `accentWash` | `#F6E3D3` | `#2E1D13` | approval card background, pending-approval banner |
| `positive` | `#3F6B3A` | `#8DBF7F` | passed gates, executed actions, `auto` chip text |
| `negative` | `#9B2C2C` | `#E58A80` | failures, denials, `deny` chip text |

Rules for color:

- `positive` and `negative` color text and 6 pt status dots only. They never fill a surface.
- `accentWash` is the only tinted surface, and only for approvals.
- Never signal state by color alone: pair a dot with a word (`running`, `failed`, `waiting`).
- Do not derive new colors with opacity. If a new shade is needed, add a token here first.

## Type

Display uses the system serif (New York, `Font.system(size:weight:design: .serif)`). Interface
text uses the system sans (SF Pro, `design: .default`). Code uses the system monospace (SF Mono,
`design: .monospaced`). No fonts are bundled. Numbers in tables and metrics use monospaced digits
(`.monospacedDigit()`).

| Token | Face | Size / line height (pt) | Weight | Use |
| --- | --- | --- | --- | --- |
| `display` | serif | 30 / 36 | regular | empty states, steward overview title |
| `title` | serif | 22 / 28 | regular | pane titles (steward name, case name) |
| `heading` | serif | 17 / 22 | semibold | section headings, decision choice |
| `body` | sans | 13 / 19 | regular | default text, rationale |
| `bodyStrong` | sans | 13 / 19 | semibold | step titles, labels, tabs, buttons |
| `caption` | sans | 11 / 15 | regular | metadata, table headers, chips |
| `overline` | sans | 10 / 14, tracking +0.8, uppercase | medium | rail group labels only |
| `mono` | mono | 12 / 18 | regular | tool names, commands, code, paths |
| `monoSmall` | mono | 11 / 16 | regular | ids, hashes, sequence numbers, table cells |

- Line height is applied as `lineSpacing = lineHeight − font line height`; store both values in
  the token.
- Sizes are the defaults at the standard text size. Tokens scale together when the user changes
  the app's text size; never hard-code a size in a view.
- Serif is for headings only. Never set body text, buttons, or tables in serif.
- Italics are allowed only in the serif, for emphasis inside a heading. Underline is reserved for
  the selected tab.

## Space and shape

### Spacing scale (4 pt grid)

| Token | pt | Typical use |
| --- | --- | --- |
| `space1` | 4 | icon-to-label gap, chip vertical padding |
| `space2` | 8 | chip horizontal padding, gap between related lines |
| `space3` | 12 | row horizontal padding, button horizontal padding, code-block padding |
| `space4` | 16 | gap between steps, card padding |
| `space5` | 24 | pane content inset, crew indent |
| `space6` | 32 | gap between sections |
| `space7` | 48 | empty-state top margin, header top margin on wide windows |

All paddings, gaps, and fixed sizes are multiples of 4. Row heights: 28 pt in the rail, 32 pt in
tables, 28 pt for buttons and the effort selector.

### Radii

| Token | pt | Use |
| --- | --- | --- |
| `radiusSmall` | 4 | buttons, chips, text fields, segments |
| `radiusMedium` | 6 | code blocks, approval cards, popovers |

No other radii. Status dots are circles. Windows use the system radius.

### Hairline rule

A hairline is exactly one device pixel: `1 / displayScale` points, drawn in `rule` (or
`ruleStrong` where this guide says so). It is the only way to separate regions. Hairlines run
edge to edge of the region they divide; they are never inset, doubled, or dashed. Never replace a
hairline with a shadow, a background change, or a thicker line, except the 2 pt selected-tab
underline and the 2 pt approval-card edge.

## Layout

```
│← 240 pt →│←24→←──────────── reading width ≤ 720 pt ─────────────→│
┌──────────┬────────────────────────────────────────────────────────┐
│ STEWARDS │    Triage keeper                Effort [low|MED|high]  │ header
│ ● Triage │    Keep the issue queue sorted and answered            │
│   run 14 ├────────────────────────────────────────────────────────┤
│   run 13 │    Stream  Changes  Ledger  Memory  Routines  Rehearsa…│ tabs 36
│ ○ Spend  ├────────────────────────────────────────────────────────┤
│          │                                                        │
│ APPROVALS│    01  Read new issues                         2m ago  │
│        2 │    02  tool  list_issues                               │
│          │    03  crew  labeler · 4 steps                         │
│          │    04  Decision  Close duplicates                      │
│          │    05  close_issue #418                         [ask]  │
│          │                                                        │
│          │                       [ Deny ]  [ Approve and run ]    │
└──────────┴────────────────────────────────────────────────────────┘
```

- **Window**: minimum 960 × 600 pt. The rail and main pane are separated by a hairline.
- **Rail**: 240 pt wide (resizable 200–320), `surface`, 12 pt horizontal row padding, 16 pt top
  inset below the title bar. Groups: `STEWARDS` and `APPROVALS` in `overline`/`inkFaint`, 24 pt
  above each group. Each steward row has a 6 pt status dot, its name in `body`, and, when
  selected, its recent runs nested 16 pt deeper with a relative time in `caption`/`inkFaint`. A
  running steward's dot is `accent` (the live indicator). The approvals entry shows its pending
  count in `bodyStrong`/`accent`; at zero the count is hidden, not shown as "0".
- **Header**: 24 pt inset on all sides. Steward name in `title`, the charter's outcome in
  `body`/`inkMuted` beneath, and the effort selector right-aligned on the title baseline.
- **Tab bar**: text tabs in `bodyStrong`, 24 pt apart, 36 pt tall, with a full-width hairline
  beneath. Order: Stream, Changes, Ledger, Memory, Routines, Rehearsals.
- **Main pane**: `canvas`, 24 pt content inset. Prose and the stream are capped at 720 pt and
  left-aligned to the inset; tables and charts may use the full pane width.
- **Action bar**: when the stream ends in a proposal that needs a decision, its buttons sit
  right-aligned at the end of the stream, inside the reading width, not in a floating footer.

## Components

Each component lists structure, then tokens. Anything not specified inherits `body` on `canvas`.

### Step

One event in a run.

- Left gutter 32 pt wide holding the sequence number (`monoSmall`, `inkFaint`, zero-padded to two
  digits).
- Title in `bodyStrong`/`ink`; relative time right-aligned in `caption`/`inkFaint` (absolute time
  in a tooltip).
- Optional body in `body`/`inkMuted`, collapsed beyond three lines with a tertiary "Show more".
- 16 pt between steps. No dividers between steps; the gutter carries the rhythm.
- A step in progress shows a 6 pt `accent` dot before its title and the word `running` in
  `caption`.

### Tool call

A step whose title is the label `tool` in `caption`/`inkFaint` followed by the tool name in
`mono`/`ink`. Input and output each sit in a code block, collapsed by default to the first line
with a disclosure triangle. Duration and exit status appear in `caption`; a failure reads
`failed` in `negative` with the error's first line in `mono`.

### Crew delegation

A step where the steward hands work to a crew member.

- Title: the label `crew` in `caption`/`inkFaint`, the member's name in `bodyStrong`, and a
  summary such as "4 steps" in `caption`.
- Expanded, the member's steps indent by `space5` (24 pt) behind a 1 px `rule` guide line at the
  left of the indent. Nesting deeper than two levels collapses to a link: "Open in its own
  stream".

### Decision

A choice the steward made.

- The label `Decision` in `caption`/`inkFaint`, the choice in `heading` (serif), rationale in
  `body`/`inkMuted`, and the decision id and time in `monoSmall`/`inkFaint`.
- Alternatives considered, if any, as a plain list in `body`/`inkMuted`.

### Proposed action

An action the steward wants to take, checked against the charter's gate.

- Kind and target in `mono` (`close_issue #418`), rationale in `body`, and a policy chip on the
  right.
- Policy chip (see Chip): `auto` text in `positive`, `ask` text in `accent` with an `accent`
  border, `deny` text in `negative`. The word is always shown; the color is a second cue.
- `auto` proposals show "Ran automatically" in `caption` once executed. `deny` proposals show
  the gate rule that blocked them in `caption`. `ask` proposals render as an approval card.

### Approval card

The one place the interface asks for a person.

- `accentWash` fill, `radiusMedium`, `space4` padding, and a 2 pt `accent` left edge.
- Content: the proposal's kind and target in `mono`, a one-sentence summary in `bodyStrong`,
  rationale in `body`/`inkMuted`, and the steward, run, and time in `caption`/`inkFaint`.
- Buttons right-aligned: Deny (secondary) then Approve (primary). The primary label names the
  effect: "Approve and run", "Ship", "Approve merge".
- The approvals view lists cards 16 pt apart, oldest first.

### Code block

`sunken` fill, `radiusMedium`, `space3` padding, `mono`/`ink`, no border. Long lines scroll
horizontally; they never wrap. Comments and prompts render in `inkMuted`. No syntax-color
palette: the monochrome rule holds in code too. A copy button (tertiary, symbol plus "Copy")
appears on hover at the top right.

### Chip

`caption`, 1 px `rule` border, `radiusSmall`, `space1` vertical and `space2` horizontal padding,
no fill. Chip text is a single lowercase word or short id. Chips never act as buttons.

### Buttons

| Kind | Fill | Border | Text | Use |
| --- | --- | --- | --- | --- |
| Primary | `accent` | none | `bodyStrong`/`accentInk` | the one action that moves work forward |
| Secondary | none | 1 px `ruleStrong` | `bodyStrong`/`ink` | alternatives: Deny, Cancel, Rehearse |
| Tertiary | none | none | `bodyStrong`/`inkMuted` | low-stakes actions: Show more, Copy |

- All buttons are 28 pt tall, `radiusSmall`, `space3` horizontal padding.
- At most one primary button is visible per pane. Primary sits rightmost.
- Pressed: the whole button drops to 70% opacity while held, the one sanctioned use of opacity.
  Disabled: text `inkFaint`, and the primary fill becomes `rule`.
- Keyboard focus: a 2 pt `accent` ring outside the button with 2 pt offset, matching the corner.
  Return triggers the primary action; Escape triggers Cancel or Deny only when the pane has focus.

### Effort selector

Replaces any model picker. A three-segment control labelled `Effort` in `caption`/`inkMuted`,
with segments `low`, `medium`, `high`.

- 28 pt tall, segments sized to their labels plus `space3` padding, 1 px `ruleStrong` borders,
  `radiusSmall` on the outer corners.
- Selected segment: `ink` fill, `canvas` text, `bodyStrong`. Others: no fill, `inkMuted` text.
- A one-line tooltip explains the trade-off ("More effort: slower, more thorough runs").

### Tabs

Text only, `bodyStrong`. Selected: `ink` with a 2 pt `ink` underline flush with the bar's
hairline. Unselected: `inkMuted`, `ink` on hover. A pending count, when relevant, follows the
label in `caption`/`inkFaint` ("Changes 3"). No pills, no icons, no background change.

### Table

Used by Ledger, Rehearsals, Routines, and Memory.

- Header row in `caption`/`inkMuted` above a 1 px `ruleStrong` hairline.
- Rows 32 pt tall, separated by `rule` hairlines; `space3` cell padding. No zebra stripes, no
  vertical rules.
- Ids, hashes, and amounts in `monoSmall`, right-aligned for numbers. Text left-aligned.
- Hover changes nothing; selection fills the row with `selection`.

### Metric chart

For trends such as run duration or rehearsal pass rate.

- One series as a 1.5 pt `ink` line. A second series, if unavoidable, is a 1.5 pt `inkFaint`
  dashed line with a legend.
- At most four horizontal gridlines in `rule`; no vertical gridlines; no area fills.
- Axis labels and units in `caption`/`inkMuted`, with monospaced digits.
- The latest point is a 6 pt `accent` dot with its value in `monoSmall` beside it.
- Height 160 pt in a pane, 48 pt as an inline sparkline in a table cell (line only, no axes).
- Every chart has an accessibility label stating the latest value and the trend.

### Empty state

Centered in the reading width, `space7` from the top.

- One sentence in `display` that says what will appear here ("No runs yet.").
- One line of guidance in `body`/`inkMuted` ("A run starts when a routine fires or you start one
  by hand.").
- At most one secondary button ("Start a run"). No illustrations.

## Motion

Motion only explains change.

- New stream steps fade in over 120 ms, ease-out. Expanding and collapsing a step or code block
  animates height over 160 ms, ease-in-out.
- The live dot pulses opacity between 100% and 40% over 1.6 s.
- No bounce, spring overshoot, parallax, sliding panes, or animated counters.
- With Reduce Motion on (`accessibilityReduceMotion`), all of the above become instant and the
  live dot stays solid. Nothing in the interface depends on motion to be understood.

## Voice and copy

- Plain, short, and in sentence case. Buttons start with a verb: "Approve",
  "Rehearse", "Pause routine", "Ship".
- Say what happened and what it affects: "Closed 3 duplicate issues", not "Action completed
  successfully".
- Use the product vocabulary consistently: a **steward** works under a **charter**; each **run**
  is a record of steps; a **crew** member takes delegated work; a **proposal** passes a **gate**
  as auto, ask, or deny; an **approval** is a person's answer to an ask; a **routine** starts runs
  on a schedule or trigger; **memory** is what a steward keeps between runs; a **case** is a saved
  scenario and the **casebook** collects them; a **rehearsal** replays cases against a charter;
  the **ledger** records every action taken; **effort** sets how hard a run works.
- Timestamps are relative in lists ("2m ago") and absolute on hover ("9 Nov 2026, 14:02").
- Errors state the cause and the next step: "The tool timed out after 30 s. Retry, or lower the
  effort."
- No exclamation marks, emoji, or jokes. No "Oops". Never blame the user.

## Accessibility

- All text tokens meet WCAG 2.2 AA (4.5:1) on every surface they appear on, in both schemes, at
  every size, so small sizes need no exceptions. The verified ratios are below.
- Hairlines (`rule`, `ruleStrong`) are decorative and never the only cue for a control or state:
  buttons and chips are identified by their text, and selection by fill or underline.
- Focus is always visible as the 2 pt `accent` ring (5.33:1 light, 7.46:1 dark against
  `canvas`, above the 3:1 non-text minimum).
- Every control is reachable by keyboard in reading order: rail, header, tabs, stream, actions.
- Status is never color alone: dots pair with words and policy chips always show their word.
- Tokens honour Increase Contrast: `rule` and `ruleStrong` switch to `inkFaint`, and `inkFaint`
  switches to `inkMuted`.
- VoiceOver: each step reads as "Step 4, decision, Close duplicates, 2 minutes ago"; approval
  cards expose Approve and Deny as named actions.

### Contrast ratios

WCAG 2.x relative-luminance contrast, rounded to two decimals.

| Text token | Light: canvas | surface | sunken | selection | accentWash | Dark: canvas | surface | sunken | selection | accentWash |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `ink` | 15.27 | 16.22 | 14.10 | 13.72 | 13.79 | 14.94 | 14.00 | 15.42 | 12.62 | 12.99 |
| `inkMuted` | 7.83 | 8.32 | 7.23 | 7.04 | 7.07 | 8.42 | 7.89 | 8.68 | 7.11 | 7.32 |
| `inkFaint` | 5.15 | 5.47 | 4.75 | 4.62 | 4.65 | 5.48 | 5.14 | 5.66 | 4.63 | 4.77 |
| `accent` | 5.33 | 5.66 | 4.92 | 4.79 | 4.81 | 7.46 | 7.00 | 7.70 | 6.31 | 6.49 |
| `positive` | 5.53 | 5.87 | 5.10 | — | 4.99 | 8.75 | 8.20 | 9.02 | — | 7.60 |
| `negative` | 6.69 | 7.10 | 6.17 | — | 6.04 | 7.32 | 6.86 | 7.55 | — | 6.36 |

Fills with text on them:

| Pair | Light | Dark |
| --- | --- | --- |
| `accentInk` on `accent` (primary button) | 6.00 | 7.57 |
| `canvas` on `ink` (selected effort segment) | 15.27 | 14.94 |

Any new color pair must be added to these tables with a ratio of at least 4.5:1 for text and
3:1 for meaningful non-text marks before it ships.

## Implementation mapping

Tokens live in the `AryaDesign` module (`Sources/AryaDesign`). Suggested Swift names:

| Guide | Swift |
| --- | --- |
| Color tokens | `AryaColor.canvas`, `AryaColor.inkMuted`, `AryaColor.accentWash`, … as `Color` values from an asset catalog with Any/Dark appearances (and High Contrast variants) |
| Type tokens | `AryaFont.display`, `AryaFont.body`, `AryaFont.monoSmall`, … plus a `.aryaText(_:)` view modifier that applies font, line spacing, and tracking together |
| Spacing | `AryaSpace.s1` … `AryaSpace.s7` (`CGFloat`) |
| Radii | `AryaRadius.small`, `AryaRadius.medium` |
| Hairline | `AryaHairline` view and `.aryaHairline(edge:color:)` modifier using `displayScale` |
| Motion | `AryaMotion.appear`, `AryaMotion.expand` (`Animation?`, `nil` under Reduce Motion) |
| Buttons | `AryaPrimaryButtonStyle`, `AryaSecondaryButtonStyle`, `AryaTertiaryButtonStyle` |
| Components | `StepRow`, `ToolCallRow`, `CrewDelegationRow`, `DecisionRow`, `ProposalRow`, `PolicyChip`, `ApprovalCard`, `CodeBlock`, `Chip`, `EffortSelector`, `TextTabBar`, `LedgerTable`, `MetricChart`, `EmptyState` |

Names in this guide and in Swift match one to one, so a value can be traced from this page to
the code by search.
