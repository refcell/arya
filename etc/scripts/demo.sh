#!/usr/bin/env bash
# Seed a demo arya home from etc/examples/triage and open the app on it. Run with `just demo`.
#
#   demo.sh   reseed .build/demo-home; look at it with `just snapshot` (offscreen renders)
#
# It never opens the app window (decision 0038).
#
# The demo home holds the triage steward, its casebook, two rehearsals and a correction, the
# runs from history.txt, two more live runs, and one reply waiting for approval in the queue. Commands
# that are not available yet (exit 69) are reported and skipped.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

case "${1:-}" in
  --no-open | "") ;;
  *) echo "usage: demo.sh" >&2; exit 64 ;;
esac

example=etc/examples/triage
home="$PWD/.build/demo-home"

log=$(mktemp "${TMPDIR:-/tmp}/arya-demo.XXXXXX")
trap 'rm -f "$log"' EXIT
bin=$(swift build --show-bin-path)
# Build only when a source is newer than the CLI; a build may wait for a CI slot.
if [ ! -x "$bin/arya" ] || [ ! -x "$bin/arya-fake-adapter" ] ||
  [ -n "$(find Sources Package.swift -newer "$bin/arya" -print -quit)" ]; then
  echo "demo: building"
  if ! just build >"$log" 2>&1; then
    cat "$log"
    echo "demo: build failed"
    exit 1
  fi
fi

rm -rf "$home"
mkdir -p "$home"

# Past steps are stamped with ARYA_CLOCK so the home shows weeks of history: setup 30 days
# ago at 08:00 UTC, one history run per day after that, the last two runs yesterday and now.
today=$(date -u +%s)
today=$((today - today % 86400))
at() { date -u -r "$(($1))" +%Y-%m-%dT%H:%M:%SZ; } # at EPOCH -> RFC 3339
base=$((today - 30 * 86400 + 8 * 3600))
step=0

# seed DESCRIPTION ARGS...: run `arya ARGS...` on the demo home, one minute after the previous
# seeded command from $base (empty base: now); a pending command is skipped.
seed() {
  local what=$1 rc=0 clock=""
  shift
  if [ -n "$base" ]; then
    clock=$(at "base + step * 60")
    step=$((step + 1))
  fi
  ARYA_CLOCK=$clock "$bin/arya" --home "$home" "$@" >"$log" 2>&1 || rc=$?
  case "$rc" in
    0) echo "  ok       $what" ;;
    69) echo "  skipped  $what ($(head -n 1 "$log" | sed 's/^arya: //'))" ;;
    *)
      echo "  FAILED   $what"
      sed 's/^/    /' "$log"
      exit 1
      ;;
  esac
}

echo "demo: seeding $home"
seed "create the home" init
sed -e "s|\"arya-fake-adapter\"|\"$bin/arya-fake-adapter\"|" \
  -e "s|\"$example/|\"$PWD/$example/|g" "$example/adapters.json" >"$home/adapters.json"
seed "define the triage steward" steward create --charter "$example/charter.json"
seed "import its casebook" casebook import st_triage "$example/casebook.jsonl"
seed "rehearse it" rehearse st_triage
# A proposed charter v2, gated on the casebook as imported: case-0006 improves, case-0005
# regresses (etc/examples/triage/charter-v2.json).
seed "propose charter v2" propose st_triage --charter "$example/charter-v2.json"
seed "correct case-0006" correct st_triage case-0006 --choice billing \
  --note "A question about the card on file is a billing question."
seed "rehearse it again" rehearse st_triage
seed "mark it ready" ready st_triage
# Weeks of past messages, oldest first: decisions, a few late routings, one memory, and one
# routine proposal (etc/examples/triage/history.txt).
day=29
while IFS= read -r message; do
  [ -n "$message" ] || continue
  base=$((today - day * 86400 + (8 + day % 5) * 3600))
  step=0
  seed "run: ${message#New message }" run st_triage --input "$message"
  day=$((day - 1))
done <"$example/history.txt"
base=$((today - 86400 + 15 * 3600))
step=0
seed "run it on a past message" run st_triage --input "New message MSG-102: App crashes on export"
seed "run: MSG-202 Where is my package?" run st_triage --input "New message MSG-202: Where is my package?"
seed "run: MSG-203 Damaged order, please refund" run st_triage \
  --input "New message MSG-203: Damaged order, please refund"
base=""
seed "run it on a new message" run st_triage \
  --input "New message MSG-201: Refund for a duplicate charge"

echo "demo: seeded $home; render it with \`just snapshot\` (offscreen, no window)"
