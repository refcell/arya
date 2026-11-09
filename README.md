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
> Pre-alpha. The design is written and the components are being built now. Nothing works end to
> end yet.

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
| Core | `Sources/AryaCore` | ids, ambient clock and randomness, charters, cases, canonical JSON | planned |
| Ledger | `Sources/AryaLedger` | hash-chained event ledger, store, repair, verify, projections | planned |
| Adapters | `Sources/AryaAdapters`, `Sources/AryaFakeAdapter`, `Sources/AryaExecAdapter` | protocol, stdio transport, fake, replay, and exec adapters, conformance | planned |
| Runtime | `Sources/AryaRuntime`, `Sources/Arya` | stewards, triggers, run loop, policy, approvals, binding proxy, crews | planned |
| Memory and routines | `Sources/AryaMemory` | notes with provenance, versioned routine library | planned |
| Eval | `Sources/AryaEval` | replay, casebooks, rehearsal, scorers, proposals, gates, metrics | planned |
| App | `Sources/AryaDesign`, `Sources/AryaApp` | design system, shell, run stream, approvals, ledger, rehearsals | planned |
| CLI | `Sources/AryaCLI` | the `arya` command, examples, end-to-end scenario | planned |

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

Planned CLI (milestones M1 and M2 in [docs/ROADMAP.md](docs/ROADMAP.md)):

```sh
arya init                                    # create an arya home
arya steward create --charter triage.json    # define a steward from a charter
arya casebook import triage past-issues.jsonl
arya rehearse triage                         # what would it have done?
arya correct triage case-0007 --choice bug   # correct one case
arya ready triage                            # allow live triggers
arya run triage                              # start a run now
arya approvals                               # list held actions
arya approve <approval>                      # approve one
arya replay <run>                            # re-run deterministically, report divergence
arya ledger verify                           # check the hash chain
```

## Testing

```sh
just test                 # all tests (Swift Testing)
just test Ledger          # only tests matching "Ledger"
just e2e                  # end-to-end scenario with the fake adapter
```

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
