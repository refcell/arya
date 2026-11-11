# Style guide

arya is one quiet, near-black canvas. A list of stewards on the left, a page that reads top to
bottom on the right, and an inspector that appears only when asked. Structure comes from
whitespace and type, not from boxes or fills. Machine text is monospace. One orange accent marks
the primary action and anything that needs a person.

This guide is normative and short on purpose. Every value is a token in `Sources/AryaDesign`;
feature views use tokens only. Decision 0036 set this direction.

## Hard rules

A screen that breaks one of these does not ship.

1. **No top bar.** The title bar is hidden and transparent; the traffic lights sit on the canvas.
   No filled strip, toolbar band, header band, or banner anywhere along the top.
2. **One canvas.** The whole window, sidebar included, is `canvas`. The sidebar, main pane, and
   inspector are separated by single hairlines. No stacked panels, no cards, no boxed sections,
   nothing nested in a frame. Code, logs, and fields may use `raised`; nothing else is filled.
3. **One purpose, one primary action.** Each screen has one primary button. Secondary detail
   goes behind a disclosure, a hover, or the inspector. Remove labels, chips, borders, and icons
   that repeat what the text already says.
4. **Obvious navigation.** Stewards on the left with their runs as threads; the main pane reads
   top to bottom; at most 4 tabs or segments on any screen.
5. **Type and density.** System sans for interface text, system monospace for machine text,
   small uppercase labels for metadata. No serif anywhere. Prose at about 1.45 line height.
   Spacing on a 4 pt grid.

## Color

Dark is the default and opens whatever the system setting; Light is a choice in settings.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `canvas` | `#0C0C0D` | `#FAFAFA` | every surface in the window |
| `raised` | `#141416` | `#F2F2F3` | code, logs, diffs, text fields; never a container |
| `selection` | `#1C1C1F` | `#E9E9EC` | selected or hovered row |
| `ink` | `#F4F4F5` | `#18181B` | primary text |
| `inkMuted` | `#A1A1AA` | `#52525B` | secondary text: outcomes, summaries, run titles |
| `inkFaint` | `#8B8B94` | `#63636C` | tertiary text: times, ids, labels |
| `rule` | `#1F1F21` | `#E4E4E7` | the hairline (white at about 8% on dark) |
| `ruleStrong` | `#2C2C30` | `#D4D4D8` | quiet button and field outlines |
| `accent` | `#F97316` | `#B4390A` | primary action, attention counts, the live dot |
| `accentFill` | `#F97316` | `#F97316` | the primary button fill and attention dots, one orange |
| `accentInk` | `#0C0C0D` | `#0C0C0D` | text on an `accentFill` fill |
| `positive` | `#4ADE80` | `#166534` | check marks, added lines, passing values |
| `negative` | `#F87171` | `#B91C1C` | cross marks, removed lines, failures |
| `warning` | `#FBBF24` | `#8A5405` | stale or at-risk values |

`positiveWash` (`#0E1F14` / `#E9F9EE`) and `negativeWash` (`#251314` / `#FDECEC`) tint added
and removed diff lines only. Older names map onto these: `surface` and `sunken` resolve to
`canvas` and `raised`; `accentWash` and `warningWash` resolve to `canvas` (no tinted boxes).

## Type

| Role | Token | Face | Size / line | Weight |
| --- | --- | --- | --- | --- |
| page title (steward name) | `title` | sans | 15 / 20 | semibold |
| section heading | `heading` | sans | 12 / 16 | semibold |
| interface text and list rows | `body` | sans | 12 / 16 | regular |
| reading text (messages, summaries) | `prose` | sans | 12 / 17.5 | regular |
| emphasis, buttons, tabs | `bodyStrong` | sans | 12 / 16 | semibold |
| secondary text, run threads | `caption` | sans | 11 / 15 | regular |
| metadata label | `label` | sans | 9.5 / 12 | semibold, UPPERCASE, tracking 0.6 |
| machine text | `mono` | mono | 11 / 15 | regular |
| machine emphasis | `monoStrong` | mono | 11 / 15 | semibold |
| times, counts, gutters | `monoSmall` | mono | 10.5 / 14 | regular |
| KPI value | `metric` | mono | 16 / 20 | medium |

The scale is dense on purpose (decision 0044): lists show many rows per screen.

Machine text means commands, tool names, paths, ids, hashes, diffs, logs, times, counts, and
metric values.

## Space and size

Spacing tokens on a 4 pt grid: `s1` 4, `s2` 8, `s3` 12, `s4` 16, `s5` 20, `s6` 24, `s7` 32.
Section gaps are `s3` or `s4` (12 to 16); `s5` and up are for sheets only.

| Size | pt |
| --- | --- |
| sidebar width | 232 (resizable 200–320) |
| inspector width | 340 |
| row height (sidebar, thread, step, table) | 24 |
| control height | 26 |
| tab bar height | 32 |
| title-bar inset (content starts below the traffic lights) | 40 |
| page padding | 24 horizontal, 20 top |
| reading width (sheets only; lists and threads fill the stream) | 680 |
| status dot | 6 |
| sparkline | 80 × 20 |
| window minimum | 960 × 600 |

Radii: 4 pt for buttons, fields, and code; pills use a capsule. Hairlines are 1 px at every
display scale (`1 / displayScale` pt) in `rule`.

## Layout

```
 ● ● ●                       │
 arya                     +  │  Support inbox triage                         [ Review 1 approval ]
                             │  Every new message is labeled and routed within one hour.
 Needs you                1  │
                             │  0.96  target 0.95   ╱╲╱‾   on track
 STEWARDS                    │
 ● Support inbox triage      │  Overview   Improve   Knowledge   Ledger
   billing · routed MSG… 2m  │  ─────────
   bug · labeled MSG-1… 1h   │
 ○ Weekly spend digest       │  PLAN …
                             │  RECENT …
 ⚙                           │
```

- **Window**: hidden title bar, full-size content, no title text. Everything is `canvas`.
- **Sidebar**: 232 pt, starts 40 pt from the top beside the traffic lights. First row: the
  `arya` wordmark in `monoStrong` and a quiet `+` (New steward). Then a "Needs you" row with an
  `accent` count when approvals are pending (hidden otherwise). Then the `STEWARDS` label and
  one row per steward; the selected steward's runs nest beneath as threads. A gear at the
  bottom opens settings in the inspector.
- **Main pane**: no header band. The page starts at the title-bar inset with the steward's name
  (`title`) and outcome (`body`/`inkMuted`), the outcome line, the one primary action
  right-aligned on the name's line, then the tab bar.
- **Stream**: the main zone fills the width between the sidebar and the inspector; lists,
  threads, and tables never sit in a narrow column.
- **Inspector**: 340 pt on the right, persistent, the same `canvas`, one hairline on its left,
  hidden with Option-Command-I. It follows the selection: an approval in Needs you (steward,
  run, policy, risk, earlier decisions on its target), a ledger event (payload, hash, prev), a
  run (status, trigger, timing, cost, steps), else the steward's context (schedule, policy,
  connections, people, effort, Edit charter, Pause). The stream keeps the plan.
- **Status bar**: 22 pt along the bottom, the same `canvas`, a hairline above, `monoSmall`
  `inkFaint`: next scheduled run, the fleet ("3 stewards · 1 behind · 1 paused"), approvals
  waiting (`accent`, opens Needs you), ledger integrity ("✓ verified 1758", `negative` when
  broken), today's spend, and a Commands ⌘K hint.
- **Settings**: app settings (home, appearance, text size) live in the Settings window, opened
  by the sidebar gear or Command-comma; no inspector repeats them.

## Components

### Controls

One control set; no native-looking controls and no bare-text actions.

- **Button** (`.aryaPrimary`, `.aryaSecondary`, `.aryaTertiary`): 24 pt, 4 pt radius, 8 pt
  padding, label in `bodyStrong`, an optional faint keycap after it (`keys: "⌥⌘P"`). Primary
  is the orange fill, one per pane, rightmost. Secondary has a `ruleStrong` hairline and
  `ink` text; tertiary a `rule` hairline and `inkMuted` text. Hover fills `raised`, press
  fills `selection`. Destructive actions are secondary, never primary.
- **Icon button** (`AryaIconButton`): 24 pt square, one symbol in `inkMuted`, a hairline and
  `raised` fill on hover; its help names the action and shortcut.
- **Segmented control** (`AryaSegmented`, also `ChoiceRow`, `EffortSelector`): 24 pt, a
  `ruleStrong` outline, hairline splits, the selected segment an `ink` fill with `canvas`
  text.
- **Toolbar** (`AryaToolbar`): a 32 pt row of controls with a hairline below, primary last.

### Status widgets

`Sparkline` (fixed or fluid width), `DayBars` (a week of runs, failures on top in
`negative`, today in `ink`), `AryaProgressBar` (3 pt track), `AryaSpinner` (10 pt arc), and
`AryaLiveDot` (a positive dot with a growing ring) for anything running now. The steward
inspector leads with a pulse: metric and trend, next wake countdown, cost today, running,
runs per day, what waits on you, recent decisions. All stewards shows the fleet pulse.

### Sidebar row

24 pt, 12 pt horizontal padding, `selection` fill with a 4 pt radius when selected. A 6 pt
attention dot (`accentFill` with pending approvals, else a neutral `inkFaint` dot, a ring when
paused); health is text: a behind-target metric value in mono `negative` on every row, the
selected on-track steward's value muted, the word `paused`; sorted needs you, behind, on
track, paused,
then the name in `body`. Counts are `monoSmall`; the "Needs you" count is `accent`.

With departments (workspace `portfolio()`), stewards sit under a fold row per department:
chevron, the name as a `label`, the count, then "2 waiting" in ink, "1 behind" in `negative`,
and a live dot while one runs. Groups are alphabetical with `Unassigned` last and keep the
need order inside; with no departments the rail is one flat list under "Stewards".

### Running

"Running" has one source: workspace `liveRuns()` (lease-held runs), carried as
`AppModel.liveLines`. The rail, status bar, inspector pulse, and portfolio read it; none reads
a run's recorded status, which stays `running` on runs a stopped process left behind.
Step, elapsed ("step 3 of ~7 · 10.0 s"), and the estimate come from `liveRuns()`; elapsed
ticks from the workspace's reading. The scheduler cell reads only `serveState().reason`:
`scheduler`, `serving · runs`, or `stopped` in `negative`. The verified cell's tooltip is
`verifyLedger().lines`.

### Thread row

A run under its steward, indented 18 pt. Title in `caption`/`inkMuted`, one line (two when selected), the full title on hover: the
run's summary (`Labeled MSG-201 as billing`), else its trigger, else "run". Never a run number
or id. The time right-aligned in `monoSmall`/`inkFaint` (`AryaTime` short style). A 6 pt
`accentFill` dot before the title marks a run waiting on a person.

### Time

Every time goes through `AryaTime`: relative under 24 hours, the date after, with the year
only when it is not the current one. Rows, cells, and meta lines use the short default (`now`,
`12m`, `3h`, `Nov 8`, `Nov 8, 2025`); only sentences say "ago" (`Changed 3h ago`, `just now`). Clock time (`AryaTime.clock`, `14:27`) only in transcript gutters; the full
date and time (`AryaTime.absolute`) only in tooltips. Views never format dates themselves.

### Choices

A short exclusive set (effort, appearance) is plain text in one row: the selected option in
`bodyStrong`/`ink` with a check mark, the rest `body`/`inkFaint`. No box, fill, or second label.

### Tab bar

At most 4 text tabs in `bodyStrong`, 20 pt apart, 32 pt tall; the selected tab is `ink` with a
2 pt `ink` underline, others `inkFaint`. One hairline under the bar. Each tab has an
accessibility title. Steward tabs: Overview (default), Improve, Knowledge, Ledger.

### Outcome line

One line under the outcome sentence: the KPI value in `metric`, `target 0.95` in
`monoSmall`/`inkFaint`, an 80 × 20 sparkline (1.5 pt `inkMuted` line, last point a 4 pt dot,
`positive` on target, `warning` off), and a status word (`on track`, `below target`) in the
matching color. No box, no chart axes.

### Step line

One quiet line per step in a run transcript: a relative time in `monoSmall`/`inkFaint` on the
left (40 pt column), the step in `body`. No prefix labels such as "action". A decision reads as
its choice in `bodyStrong` followed by its reason in `body`/`inkMuted`; never an event id.

### Tool-call row

One line in `mono`: a `positive` check or `negative` cross, the tool name in `monoStrong`, its
argument in `inkMuted`, and the duration right-aligned in `monoSmall`/`inkFaint`. Click to
expand the output below in `raised` with 4 pt radius. The policy shows only when it is `ask` or
`deny`.

### Approval block

Inline in the transcript or the Needs you list, unboxed: a `label` line (`NEEDS YOUR
APPROVAL`), the proposed action in `monoStrong` (`reply inbox:MSG-201`), the full proposed
content (the reply text) in `body`, the source it acts on (the customer's message) in
`body`/`inkMuted` under a `label` (`IN REPLY TO`), then the policy and risk that held it in
`monoSmall`/`inkFaint`. Deny (quiet) and the primary action (orange, named for its effect:
"Approve and send") sit on the left under the content. Command-Return approves and
Command-Delete denies the focused block (decision 0034). Approve and Deny carry accessibility
titles naming the action.

### Command palette

Command-K opens it over the stream, 560 pt wide, on `raised` with a 1 px `ruleStrong` border:
a search line (`body`), then up to 12 matching commands, each a 24 pt row with its title,
its group in `caption`/`inkFaint`, and its shortcut in a keycap. Matching is fuzzy (every
query character in order; prefixes and word starts rank first). ↑/↓ move, ↩ runs, Esc
closes. Lanes add commands in `FeatureRegistry.commands(_:)`.

### Keycap

A shortcut hint: `monoSmall` `inkFaint` keys inside a 1 px `rule` outline with 4 pt corners,
"⌘K", "esc". Used in the palette, the status bar, and hover hints.

### Buttons

26 pt tall, 4 pt radius, 12 pt horizontal padding, `bodyStrong`.

- **Primary**: `accentFill` fill, `accentInk` text. One per screen.
- **Quiet**: no fill, 1 px `ruleStrong` outline, `ink` text. Text-only quiet buttons
  (`inkMuted`, `ink` on hover) are for inline actions.
- Pressed 70% opacity; disabled `inkFaint` text and no fill; focus a 2 pt `accent` ring.

### Errors

Inline on the action that failed, in `caption`/`negative`, in plain words with the next step
("Could not send the reply: the adapter is not running. Start it and try again."), dismissible
with a quiet ×. Never a window-wide banner and never an error type's raw description.

### Empty state

One `body`/`inkMuted` line, and one sentence of guidance when the reason is not obvious. No
large type, no illustration.

## Dead space

One number for the reviewer and every lane, printed by `just snapshot` and kept in
`.build/snapshots/empty.tsv` (one row per PNG, `SnapshotSpace` in the snapshot test):

- Every full state renders the whole window at 1400 x 1000 pt (2800 x 2000 px). A state at
  any other size fails the snapshot test unless it is a named component part
  (`SnapshotSpace.parts`), which reports no share.
- Sampled once per point. A point is blank when its luminance is within 3% of the background
  (the most common luminance in the window), or it lies in a uniform run of 32 pt or more
  across or down: hairlines and blank fills count as empty.
- The share is the fraction of 24 pt blocks (one row tall) with no content point in them.
- Target: at most 30% on every steward and fleet screen.



New lines fade in over 120 ms; disclosures animate height over 160 ms; the live dot's ring
grows and fades every 1.6 s; hover and press take 80 ms; the inspector slides in from the
trailing edge and the palette drops in over 180 ms; the status bar's newest event pushes in
from below; a run row that just arrived holds a `selection` wash that fades over 1.2 s. With
Reduce Motion on, all of these are instant.

## Voice

Sentence case, short, specific. Buttons start with a verb and name their effect. Say what
happened and to what: "Labeled MSG-201 as billing". No exclamation marks or emoji.

### Raw ids

No machine id reaches a person outside the run's TOOLS and LOG panes: not `person:sam`,
`st_triage`, `inbox:MSG-140`, nor `snake_case_words`. Use `HumanText` and `ActionWords`.
The snapshot run reads every state's text back from the PNG and fails a state that shows one
(`SnapshotText`), in every state, strictly. Charter metric names are allowed as written.
A state may be excused for a while only by a line in `etc/app/rawtext-pending.txt` that names
its owner lane, the date, and why (`<state> <lane> <YYYY-MM-DD> <reason>`); a test rejects
any other line, and the owner deletes it once the state is clean.

## Accessibility

Every text token meets WCAG AA (4.5:1) on `canvas`, `raised`, and `selection` in both schemes;
the lowest pair is `inkFaint` and `accent` on light `selection` at 4.91. Status is never color
alone: dots pair with words, marks with counts. Every control is keyboard-reachable in reading
order: sidebar, page, inspector. Increase Contrast swaps `rule` and `ruleStrong` for `inkFaint`
and `inkFaint` for `inkMuted`.

| Text on | Dark canvas | raised | selection | Light canvas | raised | selection |
| --- | --- | --- | --- | --- | --- | --- |
| `ink` | 17.79 | 16.74 | 15.47 | 16.97 | 15.84 | 14.62 |
| `inkMuted` | 7.63 | 7.18 | 6.63 | 7.41 | 6.91 | 6.38 |
| `inkFaint` | 5.79 | 5.45 | 5.03 | 5.70 | 5.31 | 4.91 |
| `accent` | 6.98 | 6.56 | 6.06 | 5.70 | 5.32 | 4.91 |
| `positive` | 11.22 | 10.56 | 9.76 | 6.83 | 6.37 | 5.88 |
| `negative` | 7.07 | 6.65 | 6.15 | 6.20 | 5.78 | 5.34 |
| `warning` | 11.71 | 11.02 | 10.18 | 6.00 | 5.60 | 5.17 |
| `accentInk` on `accent` | 6.98 | | | 5.95 | | |

## Implementation mapping

| Guide | Swift (`Sources/AryaDesign`) |
| --- | --- |
| Colors | `AryaColor.canvas` … `AryaColor.warning`; hex in `AryaColorToken` |
| Appearance | `AryaAppearance.dark` (default), `.light` |
| Type | `AryaFont.title` … `AryaFont.metric` with `.aryaText(_:_:)` |
| Space, sizes, radii | `AryaSpace.s1` … `s7`, `AryaSize.*`, `AryaRadius.small` |
| Hairline | `AryaHairline`, `.aryaHairline(edge:)` |
| Buttons | `.aryaPrimary`, `.aryaQuiet` (`.aryaSecondary`), `.aryaTertiary` |
| Components | `SidebarRow`, `ThreadRow`, `TextTabBar`, `Sparkline` (the app's `OutcomeLine` composes it), `StepRow`, `ToolCallRow`, `ApprovalCard` (the approval block), `InlineError`, `EmptyState` |
