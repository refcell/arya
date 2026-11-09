#!/usr/bin/env bash
# End-to-end scenario (docs/ROADMAP.md, M3) with the fake adapter and a temporary home:
# define a steward from etc/examples/triage, rehearse it on its casebook, correct one case,
# mark it ready, run it live, approve the held action, check the ledger and metrics, replay
# the run with zero divergence, and verify the ledger. Run with `just e2e`.
#
#   e2e.sh           run the scenario; the temporary home is deleted afterwards
#   e2e.sh --keep    keep the temporary home and print its path
#
# Each step prints ok, PENDING (the command or the piece behind it is not built yet: exit 69
# or an unknown command), or FAIL. Steps belong to groups (setup, rehearsal, live, metrics,
# replay);
# a step runs only while its own group and the groups it needs are ok, and is skipped
# otherwise, so the live run is exercised even while rehearsal is pending.
# Exit status: 0 all ok, 1 a step failed, 2 a step is pending.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

keep=0
[ "${1:-}" = "--keep" ] && keep=1

example=etc/examples/triage
live_input="New message MSG-201: Refund for a duplicate charge"

home=$(mktemp -d "${TMPDIR:-/tmp}/arya-e2e.XXXXXX")
work=$(mktemp -d "${TMPDIR:-/tmp}/arya-e2e-work.XXXXXX")
cleanup() {
  rm -rf "$work"
  if [ "$keep" -eq 1 ]; then echo "e2e: kept home at $home"; else rm -rf "$home"; fi
}
trap cleanup EXIT
unset ARYA_HOME

echo "e2e: building"
# The same testable build as `just build` and `just test`, so after `just ci` this is a no-op.
if ! just build >"$work/build.log" 2>&1; then
  cat "$work/build.log"
  echo "e2e: FAILED to build"
  exit 1
fi
bin=$(swift build --show-bin-path)

state=ok    # overall: ok, pending, or fail (fail wins)
n=0
groups_bad=" "   # groups with a step that was not ok, space-separated
out="$work/out.json"
err="$work/err.txt"

# arya ARGS...: the CLI against the temporary home, with JSON output.
arya() { "$bin/arya" --home "$home" --json "$@"; }

# get PATH: a value from the last command's JSON output (plutil key path, `a.0.b`). Arrays
# print their element count.
get() { plutil -extract "$1" raw -o - -- "$out" 2>/dev/null; }

# expect DESCRIPTION ACTUAL WANTED: fail the current step unless ACTUAL equals WANTED.
expect() {
  [ "$2" = "$3" ] && return 0
  echo "    expected $1 to be '$3', got '$2'"
  return 1
}

# step NAME GROUP NEEDS CHECK ARGS...: run `arya ARGS...` and the shell function CHECK on its
# output. GROUP is the step's group; NEEDS lists groups (comma-separated, or -) it depends on.
step() {
  local name=$1 group=$2 needs=$3 check=$4 rc=0 dep result
  shift 4
  n=$((n + 1))
  for dep in $group ${needs//,/ }; do
    if [ "$dep" != - ] && [[ "$groups_bad" == *" $dep "* ]]; then
      printf '  %2d  %-36s skipped (needs %s)\n' "$n" "$name" "$dep"
      return 0
    fi
  done
  arya "$@" >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 69 ] || { [ "$rc" -eq 64 ] && grep -q 'unknown command' "$err"; }; then
    printf '  %2d  %-36s PENDING  %s\n' "$n" "$name" "$(head -n 1 "$err" | sed 's/^arya: //')"
    result=pending
  elif [ "$rc" -ne 0 ]; then
    printf '  %2d  %-36s FAIL (exit %d)\n' "$n" "$name" "$rc"
    sed 's/^/    /' "$err"
    result=fail
  elif ! "$check"; then
    printf '  %2d  %-36s FAIL\n' "$n" "$name"
    result=fail
  else
    printf '  %2d  %-36s ok\n' "$n" "$name"
    return 0
  fi
  groups_bad="$groups_bad$group "
  if [ "$result" = fail ]; then state=fail; elif [ "$state" = ok ]; then state=pending; fi
}

# Checks, one per step. They read the step's JSON output through `get`.
check_init() { expect status "$(get status)" created; }
check_created() { expect id "$(get summary.id)" st_triage && expect state "$(get summary.state)" draft; }
check_imported() { expect cases "$(get cases)" 8; }
check_first_rehearsal() {
  expect passed "$(get passed)" 7 && expect total "$(get total)" 8 &&
    expect "failed case" "$(get failed.0)" case-0006
}
check_corrected() { expect case "$(get case)" case-0006; }
check_second_rehearsal() { expect passed "$(get passed)" 8 && expect total "$(get total)" 8; }
check_ready() { expect state "$(get summary.state)" ready; }
check_run() {
  expect status "$(get status)" completed &&
    expect "label" "$(get actions.0.disposition)" executed &&
    expect "route" "$(get actions.1.disposition)" executed &&
    expect "reply" "$(get actions.2.disposition)" held || return 1
  run_id=$(get run)
  approval_id=$(get actions.2.approval)
}
check_approvals() { expect "pending approval" "$(get 0.id)" "$approval_id"; }
check_approved() { expect state "$(get state)" granted; }
check_ledger() {
  local executed
  executed=$(grep -c '"type" : "action.executed"' "$out" || true)
  expect "action.executed events (label, route, approved reply)" "$executed" 3
}
check_metric_event() {
  grep -q '"type" : "metric.recorded"' "$out" || { echo "    no metric.recorded event"; return 1; }
}
check_metrics() { expect metric "$(get 0.metric)" routed_within_1h && expect points "$(get 0.points)" 1; }
check_replay() { expect divergences "$(get divergences)" 0; }
check_verify() { expect ok "$(get ok)" true; }

# Copy the example adapter profile into the home with absolute paths for this build.
install_profile() {
  sed -e "s|\"arya-fake-adapter\"|\"$bin/arya-fake-adapter\"|" \
    -e "s|\"$example/|\"$PWD/$example/|g" "$example/adapters.json" >"$home/adapters.json"
}

echo "e2e: scenario (home: temporary)"
step "init a home" setup - check_init init
[ "$state" = ok ] && install_profile
step "create the triage steward" setup - check_created \
  steward create --charter "$example/charter.json"
step "import the casebook" rehearsal setup check_imported \
  casebook import st_triage "$example/casebook.jsonl"
step "rehearse: 7 of 8 pass" rehearsal setup check_first_rehearsal rehearse st_triage
step "correct case-0006" rehearsal setup check_corrected \
  correct st_triage case-0006 --choice billing
step "rehearse again: 8 of 8 pass" rehearsal setup check_second_rehearsal rehearse st_triage
step "mark the steward ready" rehearsal setup check_ready ready st_triage
step "run live on a new message" live setup check_run run st_triage --input "$live_input"
step "the reply waits for approval" live setup check_approvals approvals --steward st_triage
step "approve the reply" live setup check_approved approve "${approval_id:-unknown}" \
  --note "looks right"
step "the approved reply executed" live setup check_ledger \
  ledger tail --count 200 --steward st_triage
step "the run recorded its metric" metrics live check_metric_event \
  ledger tail --count 200 --steward st_triage
step "metric series updated" metrics live check_metrics metrics st_triage
step "replay the run: zero divergence" replay live check_replay replay "${run_id:-unknown}"
step "verify the ledger" setup - check_verify ledger verify

case "$state" in
  ok) echo "e2e: ok ($n steps)" ;;
  pending) echo "e2e: pending; each PENDING step above names the missing piece"; exit 2 ;;
  *) echo "e2e: FAILED"; exit 1 ;;
esac
