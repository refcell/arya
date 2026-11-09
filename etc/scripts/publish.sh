#!/usr/bin/env bash
# Publish local commits to main under push races (docs/DECISIONS.md 0029). Run with
# `just publish <TestFilter>`, where the filter names your lane's tests (`AryaCLITests`).
#
#   0. preflight: refuse a dirty tree or a rebase in progress, wait out a stale
#      `index.lock`, run `just fmt`, and commit any formatting it changed on its own;
#   1. fetch and rebase on origin/main, run the full `just ci`, push;
#   2. on a rejected push, rebase again; without conflicts, re-check with tidy, build, and the
#      filtered tests and push, at most three times; then go back to step 1.
#
# Docs-only changes (every commit ahead of origin/main touches only `docs/**` or `*.md`) take a
# fast path: tidy (format, secrets, denylist) and push, rebasing up to ten times, with no build
# or test, because they cannot change the Swift build (decision 0041).
#
# A rebase conflict aborts the rebase and stops: your branch and tree are as they were. Rebase
# on origin/main yourself (keep both sides), then publish again. The script never leaves a
# rebase in progress, never prompts, and prints each step with the elapsed time, so it can run
# in the background (a full `just ci` can wait a long time for a CI slot).
#
# `etc/scripts/test-publish.sh` tests it against throwaway repositories, using
# ARYA_PUBLISH_JUST (the `just` to run) and ARYA_PUBLISH_SIGN (the commit signing flag).
set -euo pipefail
export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0
started=$SECONDS
say() { printf 'publish: [%4ds] %s\n' "$((SECONDS - started))" "$*"; }
cd "$(git rev-parse --show-toplevel)"

filter=${1:?usage: publish.sh <TestFilter>}
just=${ARYA_PUBLISH_JUST:-just}
sign=${ARYA_PUBLISH_SIGN--S}
log=$(mktemp "${TMPDIR:-/tmp}/arya-publish.XXXXXX")

rebasing() {
  [ -d "$(git rev-parse --git-path rebase-merge)" ] ||
    [ -d "$(git rev-parse --git-path rebase-apply)" ]
}

# On any exit, never leave a rebase half done.
cleanup() {
  rm -f "$log"
  if rebasing; then
    git rebase --abort >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Wait up to 10 s for the index lock to go; then remove it only when no process has it open.
wait_for_index_lock() {
  local lock waited=0
  lock=$(git rev-parse --git-path index.lock)
  while [ -e "$lock" ] && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -e "$lock" ] || return 0
  if lsof -- "$lock" >/dev/null 2>&1; then
    say "a running git process holds $lock; publish again when it finishes"
    exit 1
  fi
  rm -f -- "$lock"
  say "removed a stale $lock"
}

preflight() {
  if rebasing; then
    say "a rebase is in progress; finish it (\`git rebase --continue\` or --abort) first"
    exit 1
  fi
  wait_for_index_lock
  local dirty
  dirty=$(git status --porcelain --untracked-files=no)
  if [ -n "$dirty" ]; then
    say "uncommitted changes; commit or stash them, then publish again:"
    printf '%s\n' "$dirty" | sed 's/^/    /'
    exit 1
  fi
  run "just fmt" "$just" fmt
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    # The tree was clean before `just fmt`, so every change is formatting.
    # shellcheck disable=SC2086 # $sign is empty or one flag
    git commit -q -a $sign -m "style: apply swift format"
    say "committed formatting changes"
  fi
}

rebase() {
  git fetch -q origin main
  wait_for_index_lock
  if ! git rebase -q origin/main >"$log" 2>&1; then
    local files
    files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    git rebase --abort >/dev/null 2>&1 || true
    say "rebase conflict in ${files:-unknown files}; aborted, your branch is unchanged"
    say "rebase on origin/main yourself (keep both sides), then publish again"
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

preflight
say "fetch and rebase on origin/main"
rebase
if docs_only; then
  for attempt in $(seq 1 10); do
    run "docs-only: just tidy (attempt $attempt)" "$just" tidy
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
  [ "$round" -eq 1 ] || { say "fetch and rebase on origin/main"; rebase; }
  run "full just ci" "$just" ci
  say "push"
  push && { say "pushed $(git rev-parse --short HEAD)"; exit 0; }
  for retry in 1 2 3; do
    say "push rejected; quick re-check $retry of 3"
    rebase
    run "just tidy" "$just" tidy
    run "just build" "$just" build
    run "just test $filter" "$just" test "$filter"
    say "push"
    push && { say "pushed $(git rev-parse --short HEAD)"; exit 0; }
  done
done
say "still rejected after three rounds; try again"
exit 1
