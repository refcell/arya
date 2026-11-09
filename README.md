# arya

[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=for-the-badge&logo=swift&logoColor=white)](#installation)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=for-the-badge&logo=apple&logoColor=white)](#installation)
[![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen?style=for-the-badge)](#design)
[![Status](https://img.shields.io/badge/status-pre--alpha-orange?style=for-the-badge)](#status)
[![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)](LICENSE)

arya runs persistent AI agents, called stewards, that each own an outcome instead of a task. You
give a steward an outcome, a success metric, and guardrails, connect it to your systems (through
MCP) and to people, and rehearse it against past work to see what it would have done. You correct
it and decide when it is ready. Then it works on its own: it proposes actions, holds sensitive
ones for approval, observes the results, and improves through changes that are tested against
past cases before they go live. Every run, decision, and action is recorded in an append-only
ledger you can audit and replay. arya is local-first, works with any agent harness, and comes
with a native macOS app.

<!-- App screenshot or GIF goes here once `just demo` lands (docs/ROADMAP.md, M3). -->

> [!WARNING]
> Pre-alpha. The components are being built now. `just e2e` shows how far the end-to-end
> scenario gets: each step reports ok or names the piece it is waiting for.

## Design

- **Every run is tracked.** Triggers, prompts, adapter events, tool calls, decisions, actions,
  approvals, and metrics land in one append-only, hash-chained ledger. `arya ledger verify`
  checks it; every event names who did it.
- **Durable.** All state is a projection of the ledger. Kill arya at any point and it rebuilds
  its state on restart; pending approvals and interrupted runs are never lost.
- **Deterministic replay.** Clock, ids, randomness, adapter output, tool results, and human input
  are recorded. `arya replay <run>` re-runs the runtime and reports any divergence.
- **Improvable, safely.** Changes to a steward's charter or routines are proposals, rehearsed on
  its casebook of past work and gated against the current baseline before they go live.
- **Agents propose, arya disposes.** Harnesses never act on the world directly. Actions pass
  through the charter's policy and a visible approval queue.
- **Harness-agnostic.** Agents run behind a small JSON-RPC adapter protocol
  ([docs/PROTOCOL.md](docs/PROTOCOL.md)); reference adapters wrap command-line agents.
- **Local-first, zero dependencies.** Plain files on one machine, no servers or accounts. Swift
  6 and Apple frameworks only.

The full design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Status

| Component | Path | Scope | State |
| --- | --- | --- | --- |
| Core | `Sources/AryaCore` | ids, ambient clock and randomness, charters, cases, canonical JSON | in progress: ids, `Ambient`, canonical JSON, `Charter`, `Case` |
| Ledger | `Sources/AryaLedger` | hash-chained event ledger, store, repair, verify, projections | in progress |
| Adapters | `Sources/AryaAdapters`, `Sources/AryaFakeAdapter`, `Sources/AryaExecAdapter` | protocol, stdio transport, fake, replay, and exec adapters, conformance | in progress: protocol, transport, fake adapter, conformance |
| Runtime | `Sources/AryaRuntime`, `Sources/Arya` | stewards, triggers, run loop, policy, approvals, binding proxy, crews | in progress: lifecycle, policy, approvals, executor, `Workspace` API |
| Memory and routines | `Sources/AryaMemory` | notes with provenance, versioned routine library | in progress: notes, retrieval, corrections, routine library |
| Eval | `Sources/AryaEval` | replay, casebooks, rehearsal, scorers, proposals, gates, metrics | in progress: casebooks, scorers, corrections, readiness |
| App | `Sources/AryaDesign`, `Sources/AryaApp` | design system, shell, run stream, approvals, ledger, rehearsals | in progress: tokens, components, run stream, approvals, ledger |
| CLI | `Sources/AryaCLI`, `etc/examples` | the `arya` command, examples, end-to-end scenario | in progress: every M1 and M2 command parsed and wired; `just e2e` runs |

Each area has a backlog with its decisions and progress log in [docs/lanes](docs/lanes). The plan
is in [docs/ROADMAP.md](docs/ROADMAP.md).

## Installation

arya builds from source. It requires macOS 14 or later and the Swift 6 command-line tools
(`xcode-select --install`); Xcode is not required.

```sh
git clone https://github.com/refcell/arya && cd arya
swift build -c release
```

Binaries are written to `.build/release`. [`just`](https://github.com/casey/just) wraps the
common commands; `just app` builds `Arya.app`.

## Usage

```sh
arya init                                            # create an arya home
arya steward create --charter etc/examples/triage/charter.json
arya casebook import st_triage etc/examples/triage/casebook.jsonl
arya rehearse st_triage                              # what would it have done?
arya correct st_triage case-0006 --choice billing    # correct one case
arya ready st_triage                                 # allow live triggers
arya run st_triage --input "New message MSG-201: Refund for a duplicate charge"
arya approvals                                       # list held actions
arya approve <approval>                              # approve one; it executes
arya metrics st_triage                               # outcome metric series
arya replay <run>                                    # re-run deterministically, report divergence
arya ledger verify                                   # check the hash chain
```

Every listing takes `--json`. The home defaults to `~/Library/Application Support/arya`;
`--home <dir>` or `ARYA_HOME` picks another. `arya --help` lists all commands, and
[etc/examples](etc/examples) describes the example steward used above.

## Testing

```sh
just test                 # all tests (Swift Testing)
just test Ledger          # only tests matching "Ledger"
just e2e                  # end-to-end scenario with the fake adapter
```

`just e2e` defines the example steward in a temporary home, rehearses it, corrects a case, marks
it ready, runs it live, approves the held reply, checks the ledger and metrics, replays the run,
and verifies the ledger. It exits 0 when every step passes, 1 on a failure, and 2 while a step
is still waiting on a component.

Tests never touch the network or your real arya home: they use the fake adapter and a fixed
ambient clock and id generator.

## Development

```
Package.swift            one Swift package, no dependencies
Sources/
  AryaCore/              ids, ambient clock and randomness, charters, shared types
  AryaLedger/            hash-chained event ledger, store, projections
  AryaAdapters/          adapter protocol, stdio transport, fake and replay adapters
  AryaMemory/            memory notes, routine library
  AryaRuntime/           stewards, triggers, run loop, approvals, crews
  AryaEval/              replay, rehearsal, gates, metrics
  Arya/                  Workspace facade used by the CLI and app
  AryaDesign/            design tokens and components
  AryaApp/               SwiftUI macOS app
  AryaCLI/               the `arya` command
  AryaFakeAdapter/       arya-fake-adapter
  AryaExecAdapter/       arya-exec-adapter
Tests/                   one test target per library module
etc/                     scripts, CI, app bundle metadata, examples
docs/                    architecture, protocol, style, roadmap, decisions, lanes
```

```sh
just              # list recipes
just build        # debug build
just test         # run tests
just fmt          # swift format
just tidy         # formatting, line length, secret scan, zero-dependency check
just hooks        # install the local pre-commit scan (once per clone)
just app          # build Arya.app
just run-app      # build and open Arya.app
just e2e          # end-to-end scenario
just ci           # what CI runs: tidy + build + test
just clean        # remove build output
```

- The CI workflow is staged in `etc/ci/`.
- Contributor and agent rules are in [AGENTS.md](AGENTS.md). The UI style guide is
  [docs/STYLE.md](docs/STYLE.md).

## License

[MIT](LICENSE).
