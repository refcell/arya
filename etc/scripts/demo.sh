#!/usr/bin/env bash
# Seed a demo arya home from etc/examples/triage and open the app on it. Run with `just demo`.
#
#   demo.sh   reseed .build/demo-home; look at it with `just snapshot` (offscreen renders)
#
# It never opens the app window (decision 0038).
#
# The demo home holds a small fleet from etc/examples: the triage steward (casebook, two
# rehearsals, a correction, weeks of runs, three approvals waiting), the refund follow-up
# steward (behind its target, one reply waiting), and the weekly digest steward (paused).
# Commands that are not available yet (exit 69) are reported and skipped.
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
  -e "s|\"etc/examples/|\"$PWD/etc/examples/|g" "$example/adapters.json" >"$home/adapters.json"
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
# Past inbox items and what people did, imported as cases (newest first, MSG-101 is already
# in the casebook); the review queue shows what the steward would have done next to each.
seed "import inbox history" history import st_triage --file "$example/history-export.json"
seed "rehearse with history" rehearse st_triage
seed "agree with MSG-110" review st_triage --case hist-MSG-110 --verdict agree
# Then a merged timeline, sorted by time because ledger times never go backwards: the refund
# follow-up and weekly digest stewards set up 29 days ago, weeks of runs for all three (history
# files), the digest paused two days ago, the triage steward's runs yesterday, and one now.
timeline=$(mktemp "${TMPDIR:-/tmp}/arya-demo-timeline.XXXXXX")
trap 'rm -f "$log" "$timeline"' EXIT
event() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$timeline"; } # EPOCH STEWARD WHAT ARG
day=29
while IFS= read -r message; do
  [ -n "$message" ] || continue
  event "$((today - day * 86400 + (8 + day % 5) * 3600))" st_triage run "$message"
  day=$((day - 1))
done <"$example/history.txt"
event "$((today - 29 * 86400 + 14 * 3600))" st_refunds setup etc/examples/refunds
event "$((today - 29 * 86400 + 14 * 3600 + 1800))" st_digest setup etc/examples/digest
# history.txt lines in the other examples: DAYS-AGO <tab> input.
while IFS=$'\t' read -r days message; do
  event "$((today - days * 86400 + 13 * 3600 + 1800))" st_refunds run "$message"
done <etc/examples/refunds/history.txt
while IFS=$'\t' read -r days message; do
  event "$((today - days * 86400 + 7 * 3600 + 1800))" st_digest run "$message"
done <etc/examples/digest/history.txt
event "$((today - 2 * 86400 + 16 * 3600))" st_digest pause -
yesterday=$((today - 86400 + 15 * 3600))
event "$yesterday" st_triage run "New message MSG-102: App crashes on export"
event "$((yesterday + 60))" st_triage run "New message MSG-202: Where is my package?"
event "$((yesterday + 120))" st_triage run "New message MSG-203: Damaged order, please refund"
# A quiet check about 2 h ago: the person's last look (app/visits.json below) lands right after.
event "$(($(date -u +%s) - 7200))" st_refunds run "Check approved refunds"
# People at work (connect lane): Sam and Priya ask, correct, and hand off work; reports go out.
# A message is PERSON|INTENT|TEXT; the fake scripts answer the asks and hand-offs.
event "$((today - 3 * 86400 + 10 * 3600))" st_triage message \
  "person:sam|ask|How many refund requests came in this week?"
event "$((today - 3 * 86400 + 11 * 3600))" st_triage message \
  "person:sam|correct|Duplicate charges always go to billing, even when shipping is mentioned."
event "$((today - 2 * 86400 + 17 * 3600))" st_refunds report -
event "$((today - 2 * 86400 + 14 * 3600))" st_refunds message \
  "person:priya|ask|Which approved refunds are still unconfirmed?"
event "$((today - 86400 + 9 * 3600))" st_triage report -
event "$((today - 86400 + 11 * 3600))" st_refunds message \
  "person:priya|handoff|Follow up on ORDER-1043 with the customer."
event "$((today - 86400 + 16 * 3600))" st_triage message \
  "person:priya|handoff|Check that every duplicate-charge refund went out."

while IFS=$'\t' read -r when steward what arg; do
  base=$when
  step=0
  case "$what" in
    run) seed "$steward: ${arg#New message }" run "$steward" --input "$arg" ;;
    pause) seed "pause $steward" steward pause "$steward" ;;
    report) seed "$steward: send its report" report send "$steward" ;;
    message)
      IFS='|' read -r person intent text <<<"$arg"
      seed "$steward: $person ${intent}s" message "$steward" "$text" --as "$person" \
        --intent "$intent"
      ;;
    setup)
      seed "define $steward" steward create --charter "$arg/charter.json"
      seed "import its casebook" casebook import "$steward" "$arg/casebook.jsonl"
      seed "rehearse it" rehearse "$steward"
      seed "mark it ready" ready "$steward"
      ;;
  esac
done < <(sort -n -s -k1,1 "$timeline")
base=""
seed "st_triage: MSG-201 Refund for a duplicate charge, now" run st_triage \
  --input "New message MSG-201: Refund for a duplicate charge"
seed "st_triage: Sam hands off MSG-140, now" message st_triage \
  "Take MSG-140 and close it out with the customer." --as person:sam --intent handoff

# A recent last look, about 2 h before the newest activity, so the Overview recap reads "Since
# you looked …". The app reads `app/visits.json` (newest seq seen, per steward) in the home.
# (`date -j` is the macOS form; the demo is macOS only.)
mkdir -p "$home/app"
ledger=$("$bin/arya" --home "$home" --json ledger tail --count 100000)
newest=$(printf '%s\n' "$ledger" | sed -n 's/.*"at" : "\(.*\)".*/\1/p' | tail -n 1)
cutoff=$(date -u -r "$(($(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${newest%.*}" +%s) - 7200))" \
  '+%Y-%m-%dT%H:%M:%S')
seen=$(printf '%s\n' "$ledger" | awk -v cutoff="$cutoff" '
  /"at" :/ { at = $3; gsub(/[",]/, "", at) }
  /"seq" :/ { seq = $3; gsub(/,/, "", seq); if (substr(at, 1, 19) <= cutoff) last = seq }
  END { print last }')
entries=$("$bin/arya" --home "$home" --json steward list |
  sed -n 's/.*"id" : "\(.*\)".*/"\1":'"$seen"'/p' | paste -sd, -)
printf '{"lastSeen":{%s},"v":1}\n' "$entries" >"$home/app/visits.json"

echo "demo: seeded $home; render it with \`just snapshot\` (offscreen, no window)"
