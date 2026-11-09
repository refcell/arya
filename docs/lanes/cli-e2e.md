# Lane: cli-e2e

Owns `Sources/AryaCLI`, `etc/examples`, the `just e2e` and `just demo` recipes, `README.md`, and
`etc/scripts/tidy.sh`.

Goal: **prove the whole loop works, end to end, from a clean checkout.** The `arya` command over
the `Workspace` facade, example stewards and casebooks, the end-to-end scenario, the demo home,
the README, and the tidy scan.

## Backlog

M1:
- [x] Argument parsing without dependencies: subcommands, flags, `--help`, `--home`, `--json`
  output for every listing.
- [ ] `arya init`, `arya steward create|list|show`, `arya run`, `arya approvals`,
  `arya approve|deny`, `arya ledger tail|verify`. Parsed, rendered, and tested against a fake
  backend; wire `WorkspaceBackend` once `Workspace` lands (runtime lane).
- [ ] `etc/examples/triage/`: a generic issue-triage charter, a fake-adapter script, and a
  casebook of invented past issues.

M2:
- [ ] `arya replay`, `arya casebook import|list`, `arya rehearse`, `arya correct`, `arya ready`,
  `arya propose`, `arya proposals`, `arya metrics`, `arya memory`, `arya routines`,
  `arya binding-proxy`.
- [ ] `just e2e` (CLI only, fake adapter, temporary home): create, rehearse, correct, ready,
  run, approve, replay with zero divergence, `ledger verify`; non-zero exit on any failure.

M3:
- [ ] Extend `just e2e` with the app's facade calls used by the views.
- [ ] `just demo`: seed a demo home from `etc/examples` and open the app on it.
- [ ] README: replace the placeholder with a screenshot and GIF of the demo, update the Status
  table and Usage as commands land.
- [ ] `etc/scripts/tidy.sh` upkeep: line length, formatting, secret patterns, zero
  dependencies, `CLAUDE.md` identical to `AGENTS.md`.

## Decisions

- The CLI talks to an arya home only through `CLIBackend` (`Sources/AryaCLI/Backend.swift`), which
  returns CLI view models (`Models.swift`). Those models are the `--json` contract: explicit keys,
  sorted, pretty-printed, slashes unescaped; nil optionals are omitted. `PendingBackend` stands in
  until the `Workspace` facade lands and fails every command with exit status 69.
- Exit statuses follow `sysexits`: 0 ok, 1 failure (failed run, broken ledger), 64 usage,
  65 invalid input, 66 not found, 69 not available yet. `just e2e` treats 69 as "pending".
- Home resolution: `--home`, then a non-empty `ARYA_HOME`, then the per-user default; relative
  paths resolve against the working directory, `~/` against the user's home. Read once in
  `main.swift`.
- Global options (`--home`, `--json`, `-h/--help`, `--version`) are accepted anywhere before `--`.
- CLI tests live in `Tests/AryaCLITests` and use `@testable import AryaCLI` (executable target).

## Questions

## Log
