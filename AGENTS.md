# AGENTS.md — arya

arya is a personal, open-source, local-first system of persistent AI agents that each own an
outcome, not a task. A **steward** is given a charter (outcome, success metric, guardrails),
connected to systems and people, rehearsed against past work until a person says it is ready,
and then runs on triggers, proposing actions that pass through approval gates. Every input,
decision, and action lands in an append-only ledger, so any run can be replayed exactly and any
change to a steward is tested against past cases before it goes live. arya is harness-agnostic:
agents run behind a small adapter protocol ([docs/PROTOCOL.md](docs/PROTOCOL.md)). The UI is a
native macOS app.

Read this whole file before you change anything. These rules are not optional. `CLAUDE.md` is a
byte-identical copy of this file; edit both together (`cp AGENTS.md CLAUDE.md`).

## Hard rules

1. **No company or internal data, ever.** Never push anything about any company you or the user
   work for, or have worked for, or about its internal software, services, tools, repositories,
   hostnames, projects, tickets, chat channels, people, or processes. This covers files, code
   identifiers, comments, commit messages, docs, screenshots, recordings, and test fixtures.
   arya is built only from public knowledge. When you need an example, invent a generic one
   (`tracker:ISSUE-1`, `st_triage`, `person:alex`). Do not name or copy text, logos, assets, or
   product names from other products; describe ideas in arya's own vocabulary (see Glossary).
   Public, open tools may be named generically (for example Claude Code, Codex CLI, MCP).
2. **Commit to `main` often and push right away.** No branches on the remote and no pull
   requests, ever. Your local worktree may sit on any local branch, but you publish with:
   ```sh
   git fetch origin main && git rebase origin/main && just ci && git push origin HEAD:main
   ```
   Push every small, coherent, green step, and at least every 30-60 minutes of work. If the push
   is rejected, fetch and rebase right away. A rebase without conflicts needs only
   `just tidy && just build && just test <YourModuleTests>` before pushing again, at most three
   times in a row; after that, or after any conflict (keep both sides), run the full `just ci`
   ([decision 0029](docs/DECISIONS.md)); `just publish <YourModuleTests>` does all of this.
   Never force-push `main`. Build and test only through `just`: every swift build or test
   waits for one of two machine-wide CI slots ([decision 0033](docs/DECISIONS.md)), so never
   run `swift build` or `swift test` directly. While developing run `just test
   <YourModuleTests>`; the full `just ci` runs inside `just publish`.
3. **Run `just hooks` once per clone.** It wires the local denylist and secret scan into git
   so it runs on every commit. The denylist lives untracked in the git common
   directory (`$(git rev-parse --git-common-dir)/info/denylist` and
   `denylist-case-sensitive`). Never copy its terms into tracked files, commit messages, or
   logs, and never print them in output you commit.
4. **No secrets, no personal data.** No tokens, keys, `.env` files, email addresses, usernames,
   or home-directory paths, in files or commit messages. `just tidy` scans tracked files and the
   commit message; it is a backstop, not a license.
5. **Main stays green.** `just ci` (tidy, build, test) must pass before every push. If someone
   else broke `main`, fixing it is your top priority (smallest fix).
6. **Zero third-party dependencies.** `Package.swift` has no `dependencies:` entries. Use the
   Swift standard library and Apple SDK frameworks (Foundation, CryptoKit, SwiftUI, AppKit). If
   you need something, implement the small piece yourself.
7. **Never stop, never block.** You are autonomous. When a decision is ambiguous, pick the
   simplest option that keeps runs tracked, deterministic, and improvable, write it in your lane
   file (and in [docs/DECISIONS.md](docs/DECISIONS.md) if it affects other lanes), and continue.
   If a question truly needs the project lead, write it under `## Questions` in your lane file,
   skip that item, and keep working on the next one. If blocked on another lane, build a minimal
   stub behind a protocol inside your own lane and keep going.
8. **Own your lane.** Each lane owns the paths listed in
   [docs/lanes/README.md](docs/lanes/README.md). Edit other lanes' files only for tiny
   integration fixes (a build break, a missing `public`). Shared files (`Package.swift`,
   `Justfile`, `README.md`, `docs/DECISIONS.md`, `docs/ROADMAP.md`) take small, additive edits;
   on rebase conflicts keep both sides.
9. **Never write `.github/workflows/`.** The push credential lacks workflow scope. CI is staged
   in `etc/ci/`.
10. **Determinism first.** Library code never reads the wall clock, random numbers, UUIDs, the
    environment variables, or the process list directly. It takes them from `AryaCore.Ambient`
    so runs replay exactly. All effects (adapter calls, file writes outside the store, actions)
    are recorded as ledger events.

## Style

- Swift 6 language mode, strict concurrency. `swift format` with `etc/swift-format.json`
  (`just fmt`). Lines ≤ 100 columns, docs included.
- Value types for data, `Codable` with stable, explicit `CodingKeys` for anything persisted or on
  the wire. Persisted formats are versioned (`"v": 1`).
- Small functions (aim ≤ 60 lines), no force unwraps or `try!` outside tests, errors are typed
  and handled, never swallowed.
- Names: `camelCase` members, `PascalCase` types, units last (`timeoutSeconds`, `costMicros`).
- Do not name a type after a SwiftUI or Foundation type that the app imports (`Environment`,
  `Binding`, `State`, `Scene`). Prefix it (`CharterBinding`) instead.
- UI follows `docs/STYLE.md` exactly: tokens from `AryaDesign`, never raw colors or font sizes in
  feature views.

## Testing

- `swift test` via `just test`; Swift Testing (`import Testing`, `@Test`, `#expect`). Every
  library module has tests in `Tests/<Module>Tests`.
- Use the fake adapter (`arya-fake-adapter`, `FakeAdapter`) and `Ambient.fixed(...)` for
  deterministic tests. No test touches the network or the user's real arya home.
- Persisted formats get golden-file tests under `Tests/<Module>Tests/Fixtures`.
- `just e2e` runs the end-to-end scenario ([docs/ROADMAP.md](docs/ROADMAP.md), milestone M3).
- Visual check = `just snapshot` PNGs: every key app state rendered offscreen on the demo home
  to `.build/snapshots`. Never launch the app window on the user's machine (decision 0038).

## Layout

```
Package.swift            one Swift package, no dependencies
Sources/
  AryaCore/              ids, Ambient (clock, ids, rng), charter and shared value types
  AryaLedger/            append-only hash-chained event ledger, projections, store
  AryaAdapters/          adapter protocol client, process transport, fake and replay adapters
  AryaMemory/            memory notes with provenance, versioned routine library
  AryaRuntime/           steward lifecycle, triggers, scheduler, run loop, approvals, crews
  AryaEval/              deterministic replay, rehearsal on casebooks, gates, metrics
  Arya/                  facade that wires the modules into a `Workspace` for the CLI and app
  AryaDesign/            design tokens and components from docs/STYLE.md
  AryaApp/               SwiftUI macOS app (App/, Shell/, Features/)
  AryaCLI/               the `arya` command-line interface
  AryaFakeAdapter/       `arya-fake-adapter`: scripted adapter process for tests and demos
  AryaExecAdapter/       `arya-exec-adapter`: reference adapter wrapping a command-line agent
Tests/                   one test target per library module
etc/                     scripts, CI, app bundle metadata, example stewards and casebooks
docs/                    architecture, protocol, style, roadmap, decisions, lanes
```

Executable targets are not named after their products because `Sources/arya` and
`Sources/Arya` collide on case-insensitive file systems (the macOS default).

## Glossary

| Term | Meaning |
| --- | --- |
| steward | a persistent agent that owns one outcome |
| charter | a steward's outcome, metric, guardrails, bindings, triggers, approval policy, effort |
| binding | a connection to a system (an MCP server) or a person (a contact channel) |
| run | one execution of a steward, started by a trigger, a case, or a person |
| case / casebook | one past unit of work with its known result / a versioned set of them |
| rehearsal | running a steward over a casebook offline and scoring what it would have done |
| proposal | a change to a charter or routine that must pass a gate before it goes live |
| gate | the rehearsal check a proposal must pass (no regression against the baseline) |
| routine | versioned code a steward wrote for itself, so repeated work becomes code |
| memory | notes a steward keeps across runs, each with provenance |
| approval | a sensitive action held until a person approves or denies it |
| crew | sub-agents a run fans work out to |
| ledger | the append-only, hash-chained log of every event |
| effort | low / medium / high, mapped to models by each adapter |

## Commits

- Conventional, imperative subject: `feat(ledger): add hash chain verification`,
  `docs: add architecture`.
- Commit messages carry no co-author or attribution trailers (`Co-authored-by:` and the like).
  Commit through a subshell, `sh -c 'git commit -S -m "docs: add architecture"'`, so editor or
  tool hooks cannot append one, and check `git log -1 --format=%B` before every push.
- Small and frequent. Never commit `.build/`, `.swiftpm/`, `.cache/`, `.pi/`, `.claude/`, or a
  local arya home.
- Commits must be GPG-signed with a committer email equal to the repo's `user.email` (the global
  config does this). Never bypass or disable hooks (`--no-verify`, environment overrides). If
  a push is blocked as unverified, fix the commits with
  `git commit --amend --no-edit --reset-author -S` and push again.
