#!/usr/bin/env bash
# Publish local commits to main under push races (docs/DECISIONS.md 0029). Run with
# `just publish <TestFilter>`, where the filter names your lane's tests (`AryaCLITests`).
#
#   1. fetch and rebase on origin/main, run the full `just ci`, push;
#   2. on a rejected push, rebase again; without conflicts, re-check with tidy, build, and the
#      filtered tests and push, at most three times; then go back to step 1.
# A rebase conflict stops the script: resolve it (keep both sides), `git rebase --continue`,
# and run it again, which starts with the full `just ci`.
#
# Docs-only changes (every commit ahead of origin/main touches only `docs/**` or `*.md`) take a
# fast path: tidy (format, secrets, denylist) and push, rebasing up to ten times, with no build
# or test, because they cannot change the Swift build (decision 0039).
#
# It never prompts and prints each step with the elapsed time, so it can run in the background
# (a full `just ci` can wait for a CI slot for a long time on a busy machine).
set -euo pipefail
export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0
started=$SECONDS
say() { printf 'publish: [%4ds] %s\n' "$((SECONDS - started))" "$*"; }
cd "$(git rev-parse --show-toplevel)"

filter=${1:?usage: publish.sh <TestFilter>}
log=$(mktemp "${TMPDIR:-/tmp}/arya-publish.XXXXXX")
trap 'rm -f "$log"' EXIT

rebase() {
  git fetch -q origin main
  if ! git rebase -q origin/main; then
    say "rebase conflict; resolve it, run \`git rebase --continue\`, then publish again"
    exit 1
  fi
  if [ -z "$(git rev-list origin/main..HEAD)" ]; then
    say "nothing to push"
    exit 0
  fi
}

# run LABEL COMMAND...: run quietly, print the log tail on failure.
run() {
  local label=$1
  shift
  say "$label"
  if ! "$@" >"$log" 2>&1; then
    grep -v 'ld: warning' "$log" | tail -40
    say "$label failed"
    exit 1
  fi
}

push() { git push -q origin HEAD:main 2>/dev/null; }

# True when every file changed since origin/main is documentation.
docs_only() {
  local files
  files=$(git diff --name-only origin/main...HEAD)
  [ -n "$files" ] && ! grep -qvE '^docs/|\.md$' <<<"$files"
}

rebase
if docs_only; then
  for attempt in $(seq 1 10); do
    run "docs-only: just tidy (attempt $attempt)" just tidy
    say "push"
    push && { say "pushed $(git rev-parse --short HEAD)"; exit 0; }
    say "push rejected; rebasing"
    rebase
    docs_only || break
  done
  docs_only && { say "still rejected after ten docs-only attempts; try again"; exit 1; }
  say "changes are no longer docs-only; running the full check"
fi

for round in 1 2 3; do
  say "fetch and rebase on origin/main"
  rebase
  run "full just ci" just ci
  say "push"
  push && { say "pushed $(git rev-parse --short HEAD)"; exit 0; }
  for retry in 1 2 3; do
    say "push rejected; quick re-check $retry of 3"
    rebase
    run "just tidy" just tidy
    run "just build" just build
    run "just test $filter" just test "$filter"
    say "push"
    push && { say "pushed $(git rev-parse --short HEAD)"; exit 0; }
  done
done
say "still rejected after three rounds; try again"
exit 1
