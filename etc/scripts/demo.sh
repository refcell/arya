#!/usr/bin/env bash
# Seed a demo arya home from etc/examples/triage and open the app on it. Run with `just demo`.
#
#   demo.sh             reseed .build/demo-home, build Arya.app, and open it on the demo home
#   demo.sh --no-open   reseed only (used to check the seeding)
#
# The demo home holds the triage steward, its casebook, two rehearsals and a correction, the
# runs from history.txt, two more live runs, and one reply waiting for approval in the queue. Commands
# that are not available yet (exit 69) are reported and skipped.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

open_app=1
[ "${1:-}" = "--no-open" ] && open_app=0

example=etc/examples/triage
home="$PWD/.build/demo-home"

echo "demo: building"
log=$(mktemp "${TMPDIR:-/tmp}/arya-demo.XXXXXX")
trap 'rm -f "$log"' EXIT
if ! just build >"$log" 2>&1; then
  cat "$log"
  echo "demo: build failed"
  exit 1
fi
bin=$(swift build --show-bin-path)

rm -rf "$home"
mkdir -p "$home"

# seed DESCRIPTION ARGS...: run `arya ARGS...` on the demo home; a pending command is skipped.
seed() {
  local what=$1 rc=0
  shift
  "$bin/arya" --home "$home" "$@" >"$log" 2>&1 || rc=$?
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
seed "correct case-0006" correct st_triage case-0006 --choice billing \
  --note "A question about the card on file is a billing question."
seed "rehearse it again" rehearse st_triage
seed "mark it ready" ready st_triage
# Weeks of past messages, oldest first: decisions, a few late routings, one memory, and one
# routine proposal (etc/examples/triage/history.txt).
while IFS= read -r message; do
  [ -n "$message" ] || continue
  seed "run: ${message#New message }" run st_triage --input "$message"
done <"$example/history.txt"
seed "run it on a past message" run st_triage --input "New message MSG-102: App crashes on export"
seed "run it on a new message" run st_triage \
  --input "New message MSG-201: Refund for a duplicate charge"

if [ "$open_app" -eq 0 ]; then
  echo "demo: seeded; open the app with \`just demo\`"
  exit 0
fi
echo "demo: bundling the app"
if ! just app >"$log" 2>&1; then
  cat "$log"
  echo "demo: app bundle failed"
  exit 1
fi
open -n .build/Arya.app --args --home "$home"
echo "demo: opened Arya.app on $home"
