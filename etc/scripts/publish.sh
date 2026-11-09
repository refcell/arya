#!/usr/bin/env bash
# Publish local commits to main under push races (docs/DECISIONS.md 0029). Run with
# `just publish <TestFilter>`, where the filter names your lane's tests (`AryaCLITests`).
#
#   1. fetch and rebase on origin/main, run the full `just ci`, push;
#   2. on a rejected push, rebase again; without conflicts, re-check with tidy, build, and the
#      filtered tests and push, at most three times; then go back to step 1.
# A rebase conflict stops the script: resolve it (keep both sides), `git rebase --continue`,
# and run it again, which starts with the full `just ci`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

filter=${1:?usage: publish.sh <TestFilter>}
log=$(mktemp "${TMPDIR:-/tmp}/arya-publish.XXXXXX")
trap 'rm -f "$log"' EXIT

rebase() {
  git fetch -q origin main
  if ! git rebase -q origin/main; then
    echo "publish: rebase conflict; resolve it, run \`git rebase --continue\`, then publish again"
    exit 1
  fi
  if [ -z "$(git rev-list origin/main..HEAD)" ]; then
    echo "publish: nothing to push"
    exit 0
  fi
}

# run LABEL COMMAND...: run quietly, print the log tail on failure.
run() {
  local label=$1
  shift
  if ! "$@" >"$log" 2>&1; then
    grep -v 'ld: warning' "$log" | tail -40
    echo "publish: $label failed"
    exit 1
  fi
}

push() { git push -q origin HEAD:main 2>/dev/null; }

for round in 1 2 3; do
  rebase
  echo "publish: full just ci"
  run "just ci" just ci
  push && { echo "publish: pushed $(git rev-parse --short HEAD)"; exit 0; }
  for retry in 1 2 3; do
    echo "publish: push rejected; quick re-check $retry of 3"
    rebase
    run "just tidy" just tidy
    run "just build" just build
    run "just test $filter" just test "$filter"
    push && { echo "publish: pushed $(git rev-parse --short HEAD)"; exit 0; }
  done
done
echo "publish: still rejected after three rounds; try again"
exit 1
