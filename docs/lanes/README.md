# Lanes

Work is split into lanes. Each lane is owned by one autonomous agent session and owns the paths
listed below. A lane file is the lane's living backlog and log: the owning agent keeps its
checklist current, records decisions, and appends a short dated log line after each push. Other
lanes read it to find interfaces. `Tests/<Module>Tests` belongs to the lane that owns
`Sources/<Module>`. `docs/PROTOCOL.md`, `docs/STYLE.md`, `README.md`, and
`etc/scripts/tidy.sh` pass from the phase-1 sessions to their lanes once phase 1 is done.

| Lane | File | Owns |
| --- | --- | --- |
| ledger | [ledger.md](ledger.md) | `Sources/AryaCore`, `Sources/AryaLedger`, `Tests/AryaCoreTests`, `Tests/AryaLedgerTests` |
| adapters | [adapters.md](adapters.md) | `Sources/AryaAdapters`, `Sources/AryaFakeAdapter`, `Sources/AryaExecAdapter`, `Tests/AryaAdaptersTests`, `docs/PROTOCOL.md` |
| runtime | [runtime.md](runtime.md) | `Sources/AryaRuntime`, `Tests/AryaRuntimeTests` |
| workspace | [workspace.md](workspace.md) | `Sources/Arya`, `Tests/AryaTests` |
| memory | [memory.md](memory.md) | `Sources/AryaMemory`, `Tests/AryaMemoryTests` |
| eval | [eval.md](eval.md) | `Sources/AryaEval`, `Tests/AryaEvalTests` |
| app-shell | [app-shell.md](app-shell.md) | `Sources/AryaDesign`, `Sources/AryaApp/App`, `Sources/AryaApp/Shell`, `Tests/AryaDesignTests`, `etc/app`, `docs/STYLE.md` |
| app-views | [app-views.md](app-views.md) | `Sources/AryaApp/Features` (shares `Tests/AryaAppTests` with app-shell) |
| cli-e2e | [cli-e2e.md](cli-e2e.md) | `Sources/AryaCLI`, `etc/examples`, `just e2e`, `just demo`, `README.md`, `etc/scripts/tidy.sh` |

Shared files (`Package.swift`, `Justfile`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`,
`docs/ROADMAP.md`, `AGENTS.md`) take small, additive edits from any lane; keep both sides on
rebase conflicts. A change to `AGENTS.md` is copied to `CLAUDE.md` in the same commit.

## Dependencies between lanes

```
ledger ─▶ adapters ─┐
   │                ├─▶ runtime ─▶ eval ─▶ workspace ─▶ cli-e2e
   └────▶ memory ───┘                          │
                                               └─▶ app-shell ─▶ app-views
```

Do not wait for an upstream lane. Code against the interface described in
[ARCHITECTURE.md](../ARCHITECTURE.md) and [PROTOCOL.md](../PROTOCOL.md); if it has not landed,
write a minimal stub behind a protocol inside your own module, and delete it once the real one
lands. When you publish an interface another lane needs, say so in your log line.

## Lane protocol

1. Read [AGENTS.md](../../AGENTS.md), [ARCHITECTURE.md](../ARCHITECTURE.md),
   [PROTOCOL.md](../PROTOCOL.md), [DECISIONS.md](../DECISIONS.md), your lane file, and, for UI
   lanes, [STYLE.md](../STYLE.md). Run `just hooks` once.
2. Pick the first unchecked item in your backlog. Implement it with tests (Swift Testing, the
   fake adapter, `Ambient.fixed`), keeping it small enough to publish within 30-60 minutes.
3. Publish: `git fetch origin main && git rebase origin/main && just ci && git push origin
   HEAD:main`. No remote branches, no pull requests.
4. Tick the item, add a dated log line (`- 2026-11-10: hash chain and verify landed (abc1234)`),
   and push. Record decisions under `## Decisions` (and in `docs/DECISIONS.md` if they affect
   other lanes). Put questions for the project lead under `## Questions` and move on.
5. Repeat. When the backlog is empty, extend it with the next most valuable work toward the
   M3 end-to-end scenario and then M4, and keep going.
