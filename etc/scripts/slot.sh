#!/usr/bin/env bash
# Run a command in one of a few machine-wide CI slots (docs/DECISIONS.md, "CI slot lock"), so
# at most ARYA_CI_SLOTS (default 2) swift builds and test runs share the machine across every
# worktree. Slots are lock files in the shared git dir held with lockf(1) for the command's
# lifetime; a killed command releases its slot. Usage: etc/scripts/slot.sh swift build ...
#
# Wrap only the innermost swift invocation: a command that already holds a slot and waits for
# another can deadlock when every slot is held the same way.
set -uo pipefail

[ $# -gt 0 ] || { echo "usage: slot.sh <command> [args...]" >&2; exit 64; }
dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || dir=${TMPDIR:-/tmp}
slots=${ARYA_CI_SLOTS:-2}
waiting=false

# lockf exits 75 (EX_TEMPFAIL) when the slot is taken; a command that exits 75 itself is
# reported as 1 so the two cannot be confused.
inner='"$@"; s=$?; [ "$s" -eq 75 ] && s=1; exit "$s"'

while :; do
  for ((n = 1; n <= slots; n++)); do
    /usr/bin/lockf -k -s -t 0 "$dir/arya-ci-slot-$n.lock" /bin/sh -c "$inner" sh "$@"
    status=$?
    [ "$status" -eq 75 ] || exit "$status"
  done
  if ! $waiting; then
    echo "waiting for a CI slot ($slots in use)" >&2
    waiting=true
  fi
  sleep 2
done
