#!/usr/bin/env bash
# End-to-end scenario (docs/ROADMAP.md, M3) with the fake adapter and a temporary home:
# define a steward from etc/examples/triage, rehearse it on its casebook, correct one case,
# mark it ready, run it live, approve the held action, check the ledger and metrics, replay
# the run with zero divergence; then a fleet of three stewards (etc/examples/refunds and a
# digest steward at `suggest` autonomy) with pause and resume, a policy hold and an autonomy
# hold, deny and approve, a gated charter proposal that leaves the live steward ready, a run
# correction that becomes a case and a memory, a retract, a charter editor proposal (one more
# guardrail) that passes its gate and live readiness, a crew run whose child drafts the reply
# and only proposes, approver rules (a refused approver is recorded), aborting a running run
# from another process, a person's message (ask, correct) and the progress report, a
# steward's policy and approvers, undoing an executed label, retention, a signed export that
# checks on its own and imports into a fresh home, the docs-only publish path
# (etc/scripts/test-publish.sh docs-only), and verify the ledger. Run with `just e2e`.
#
#   e2e.sh           run the scenario; the temporary home is deleted afterwards
#   e2e.sh --keep    keep the temporary home and print its path
#
# Each step prints ok, PENDING (the command or the piece behind it is not built yet: exit 69
# or an unknown command), or FAIL. Steps belong to groups (setup, rehearsal, live, metrics,
# replay, fleet, holds, improve, crew, connect, abort, governance, publish);
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
check_history() { expect added "$(get added)" 24 && expect duplicate "$(get duplicates.0)" MSG-101; }
check_history_rehearsal() { expect passed "$(get passed)" 28 && expect total "$(get total)" 33; }
check_review_queue() {
  expect "next case" "$(get next.caseID)" hist-MSG-113 && expect total "$(get total)" 33 &&
    expect reviewed "$(get reviewed)" 2
}
check_casebook_build() {
  [ "$(get added)" -gt 0 ] || { echo "    no cases from runs"; return 1; }
  case "$(get summary)" in "Added "*" from runs to "*) ;; *) echo "    $(get summary)"; return 1 ;; esac
}
check_history_steward() { expect id "$(get summary.id)" st_history; }
check_binding_history() {
  expect added "$(get added)" 40 && expect casebook "$(get casebook)" history &&
    expect "first case" "$(get added.0)" hist-MSG-040
}
check_folder_steward() { expect id "$(get summary.id)" st_folder; }
check_folder_history() {
  expect added "$(get added)" 25 && expect invalid "$(get invalid)" 0 &&
    expect "first case" "$(get added.0)" hist-MSG-136
}
check_reviewed() { expect reviewed "$(get reviewed)" 3 && expect agreed "$(get agreed)" 1; }
# v1 from the live-run correction, v2 and v3 from the two reviews; each check is scored.
check_checks() {
  expect version "$(get version)" 3 || return 1
  [ "$(get total)" -gt 0 ] && [ "$(get scored)" -gt 0 ] || { echo "    no scored checks"; return 1; }
  case "$(get sentence)" in
    "Checks v3: passes "*) ;;
    *) echo "    sentence: $(get sentence)"; return 1 ;;
  esac
}
check_verify() { expect ok "$(get ok)" true; }
check_refunds() { expect id "$(get summary.id)" st_refunds; }
check_digest() { expect id "$(get summary.id)" st_digest; }
check_fleet() { expect stewards "$(grep -c '"charterVersion"' "$out")" 3; }
check_fleet_read() {
  local i needs seen_clear=no
  expect stewards "$(grep -c '"needsYou"' "$out")" 3 || return 1
  for i in 0 1 2; do
    needs=$(get "$i.needsYou")
    [ -n "$(get "$i.target")" ] || { echo "    $(get "$i.steward") has no target"; return 1; }
    if [ "$needs" -eq 0 ]; then
      seen_clear=yes
    elif [ "$seen_clear" = yes ]; then
      echo "    $(get "$i.steward") needs you but is listed after a steward that does not"
      return 1
    fi
  done
}
check_paused() { expect state "$(get summary.state)" paused; }
check_resumed() { expect state "$(get summary.state)" draft; }
check_policy_hold() {
  expect "reply" "$(get actions.1.disposition)" held || return 1
  refund_approval=$(get actions.1.approval)
}
check_autonomy_hold() {
  expect "post" "$(get actions.0.disposition)" held || return 1
  digest_approval=$(get actions.0.approval)
}
check_hold_reasons() {
  expect "refund reply held by" "$(get 0.heldBy)" rule:reply &&
    expect "digest post held by" "$(get 1.heldBy | cut -d: -f1-2)" autonomy:suggest &&
    [ -n "$(get 1.heldBecause)" ] &&
    expect "digest post approvers" "$(get 1.approvers.0)" local
}
check_refusal_recorded() {
  expect "approval.refused events" "$(grep -c '"approval.refused"' "$out")" 1
}
# The process running it may not have stopped yet when `run abort` returns.
check_abort_requested() {
  expect run "$(get run)" "${long_run:-}" || return 1
  case "$(get status)" in running | stopped) ;; *) echo "    status $(get status)"; return 1 ;; esac
}
check_aborted() {
  expect run "$(get run)" "${long_run:-}" &&
    expect status "$(get status)" stopped && expect "actions" "$(get actions)" 0
}
check_facts() {
  expect status "$(get status)" finished && expect drafted "$(get actionsDrafted)" 3 &&
    expect waiting "$(get actionsWaiting)" 0 && expect "dry run" "$(get dryRun)" true
}
check_live_running() {
  expect running "$(get running.run)" "${long_run:-}" && expect status "$(get running.status)" running
}
check_live_idle() { expect running "$(get running.run)" ""; }
check_onboarding() {
  expect "history cases" "$(get historyCases)" 24 && expect steps "$(get steps)" 7 &&
    expect "ready" "$(get ready)" false
}
check_gate() {
  expect ready "$(get ready)" false &&
    expect review "$(get conditions.0.detail)" "1 of 10 agreed reviews"
}
# The e2e home only drafts (dry run), and drafts are never graded.
check_trajectories() { expect graded "$(get good)/$(get bad)" 0/0; }
check_metric_statuses() {
  expect role "$(get 0.role)" primary && expect metric "$(get 0.name)" routed_within_1h &&
    case "$(get 0.line)" in *"on track"*) ;; *) echo "    $(get 0.line)"; return 1 ;; esac
}
check_denied() { expect state "$(get state)" denied; }
# Governance (ledger lane): policy and approvers, undo, retention, signed export and import.
check_policy() {
  expect "reply approvers" "$(get bindings.0.actions.2.approvers.1)" person:sam &&
    expect "fallback" "$(get fallback)" ask
}
check_undo_options() {
  expect "undoable" "$(get 0.kind)" label && expect "with" "$(get 0.with)" unlabel || return 1
  undo_action=$(get 0.action)
}
# Unlabel is `ask` in the triage policy, so the compensation waits for a person.
check_undone() { expect "compensation" "$(get option.with)" unlabel && expect decision "$(get decision)" ask; }
check_retention() { expect "triage keeps" "$(get stewards.0.days)" 90; }
check_exported() { expect issues "$(get issues)" 0 && expect steward "$(get steward)" st_triage; }
check_export_verified() { expect issues "$(get issues)" 0; }
check_steward_imported() { expect steward "$(get steward)" st_triage; }
check_proposal() { expect state "$(get state)" failed && expect regression "$(get regressions.0)" case-0005; }
check_still_ready() {
  expect state "$(get summary.state)" ready && expect version "$(get summary.charterVersion)" 1
}
check_run_corrected() {
  expect case "$(get case)" "run-${run_id:-}" || return 1
  memory_id=$(get memory)
  [ -n "$memory_id" ] || { echo "    no memory note"; return 1; }
}
check_new_case() { expect "cases in the newest casebook" "$(get 0.cases)" 9; }
check_remembered() { grep -q "\"${memory_id:-none}\"" "$out" || { echo "    $memory_id not in memory"; return 1; }; }
check_retracted() { expect retracted "$(get retracted)" true; }
check_editor_proposal() {
  expect state "$(get state)" passed && expect regressions "$(get regressions)" 0 || return 1
  proposal_id=$(get id)
}
check_readiness() {
  expect ready "$(get ready)" true && [ "$(get runsChecked)" -ge 1 ] ||
    { echo "    $(get summary)"; return 1; }
}
check_crew() {
  # In-run host/delegate: the child answers inside the parent run, so no join run follows.
  expect status "$(get status)" completed && expect "crew children" "$(get crew)" 1 || return 1
  crew_parent=$(get run)
  crew_child=$(get crew.0)
}
check_child() {
  expect parent "$(get parent)" "${crew_parent:-}" &&
    expect "drafted reply" "$(get actions.0.disposition)" proposed
}
check_asked() {
  [ -n "$(get event)" ] && [ -n "$(get run.id)" ] ||
    { echo "    no answering run"; return 1; }
}
check_message_kept() { [ -n "$(get note)" ] || { echo "    the correction became no memory"; return 1; }; }
check_report() {
  [ "$(get lines)" -ge 1 ] && expect "goes to" "$(get to.0.person)" person:sam ||
    { echo "    an empty report, or not to person:sam"; return 1; }
}
check_forgotten() { ! grep -q "\"${memory_id:-none}\"" "$out" || { echo "    $memory_id still recalled"; return 1; }; }

# refused_step NAME GROUP NEEDS TEXT ARGS...: `arya ARGS...` must fail with TEXT on stderr.
refused_step() {
  local name=$1 group=$2 needs=$3 text=$4 dep
  shift 4
  n=$((n + 1))
  for dep in $group ${needs//,/ }; do
    if [ "$dep" != - ] && [[ "$groups_bad" == *" $dep "* ]]; then
      printf '  %2d  %-36s skipped (needs %s)\n' "$n" "$name" "$dep"
      return 0
    fi
  done
  if ! arya "$@" >"$out" 2>"$err" && grep -F "$text" "$err" >/dev/null; then
    printf '  %2d  %-36s ok\n' "$n" "$name"
    return 0
  fi
  printf '  %2d  %-36s FAIL (wanted a refusal: %s)\n' "$n" "$name" "$text"
  sed 's/^/    /' "$err"
  groups_bad="$groups_bad$group "
  state=fail
}

# start_long_run: run MSG-204 (the script sleeps 30 s) in the background, so another process
# can abort it; sets long_pid and long_run (empty if it never started).
start_long_run() {
  local before
  before=$(arya ledger tail -n 1 | plutil -extract 0.seq raw -o - - 2>/dev/null || echo 0)
  arya run st_triage --input "New message MSG-204: Please export every ticket I ever filed" \
    >"$work/long.json" 2>&1 &
  long_pid=$!
  long_run=""
  for _ in $(seq 1 200); do
    long_run=$(arya ledger tail -n 50 | awk -v before="$before" '
      /"run" :/ { run = $3; gsub(/[",]/, "", run) }
      /"seq" :/ { seq = $3; gsub(/,/, "", seq) }
      /"type" : "run.started"/ { if (seq + 0 > before + 0) print run }' | tail -n 1)
    [ -n "$long_run" ] && return 0
    sleep 0.1
  done
}

# script_step NAME GROUP COMMAND...: a step that runs a script instead of the CLI.
script_step() {
  local name=$1 group=$2
  shift 2
  n=$((n + 1))
  if "$@" >"$work/script.log" 2>&1; then
    printf '  %2d  %-36s ok\n' "$n" "$name"
  else
    printf '  %2d  %-36s FAIL\n' "$n" "$name"
    sed 's/^/    /' "$work/script.log"
    groups_bad="$groups_bad$group "
    state=fail
  fi
}

# Copy the example adapter profile into the home with absolute paths for this build.
install_profile() {
  sed -e "s|\"arya-fake-adapter\"|\"$bin/arya-fake-adapter\"|" \
    -e "s|\"etc/examples/|\"$PWD/etc/examples/|g" "$example/adapters.json" >"$home/adapters.json"
  # The digest steward at `suggest` autonomy: every action waits for a person.
  cp etc/examples/digest/charter.json "$work/digest.json"
  plutil -insert autonomy -string suggest "$work/digest.json"
  # Only the person at this home may approve its posts.
  plutil -insert policy.approvers -json \
    '[{"action":"post","people":["local"],"note":"Only the team lead posts the digest"}]' \
    "$work/digest.json"
  # What the charter editor proposes: the live triage charter with one more guardrail.
  cp "$example/charter.json" "$work/edited.json"
  plutil -insert guardrails.3 -string "Never promise a delivery date." "$work/edited.json"
  # A triage steward whose inbox binding is the fake binding serving 40 past messages, read
  # through its `history` tool (docs/PROTOCOL.md, "Binding conventions").
  cp "$example/charter.json" "$work/history.json"
  plutil -replace id -string st_history "$work/history.json"
  plutil -replace bindings.0.command -string "$bin/arya-fake-adapter" "$work/history.json"
  plutil -replace bindings.0.args -json "[\"--binding\", \"$PWD/$example/inbox-history.json\"]" \
    "$work/history.json"
  plutil -insert bindings.0.read.2 -string history "$work/history.json"
  # The same steward on a real local connector: `arya-binding folder` serving the triage
  # history export as the folder's history.json (docs/PROTOCOL.md, "Local connectors").
  mkdir -p "$work/inbox-folder"
  cp "$example/history-export.json" "$work/inbox-folder/history.json"
  cp "$work/history.json" "$work/folder.json"
  plutil -replace id -string st_folder "$work/folder.json"
  plutil -replace bindings.0.command -string "$bin/arya-binding" "$work/folder.json"
  plutil -replace bindings.0.args -json "[\"folder\", \"$work/inbox-folder\"]" \
    "$work/folder.json"
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
step "run facts: 3 drafted, none waiting" live live check_facts run facts "${run_id:-unknown}"
step "the run recorded its metric" metrics live check_metric_event \
  ledger tail --count 200 --steward st_triage
step "metric series updated" metrics live check_metrics metrics st_triage
step "replay the run: zero divergence" replay live check_replay replay "${run_id:-unknown}"
step "create the refund follow-up steward" fleet setup check_refunds \
  steward create --charter etc/examples/refunds/charter.json
step "create the digest steward (suggest)" fleet setup check_digest \
  steward create --charter "$work/digest.json"
step "the fleet lists three stewards" fleet setup check_fleet steward list
step "pause the refund steward" fleet setup check_paused steward pause st_refunds
step "resume it" fleet setup check_resumed steward resume st_refunds
step "refund reply: held by policy" holds fleet check_policy_hold \
  run st_refunds --input "Refund approved for ORDER-1043"
step "digest post: held by autonomy" holds fleet check_autonomy_hold \
  run st_digest --input "Weekly digest 1"
step "approvals explain each hold" holds fleet check_hold_reasons approvals
step "deny the refund reply" holds fleet check_denied deny "${refund_approval:-unknown}" \
  --note "billing already wrote"
refused_step "sam may not approve the digest post" holds fleet "may not approve post" \
  approve "${digest_approval:-unknown}" --as person:sam
step "the refusal is recorded" holds fleet check_refusal_recorded ledger tail -n 5
step "approve the digest post" holds fleet check_approved approve "${digest_approval:-unknown}"
step "fleet: who needs you, each vs target" fleet holds check_fleet_read fleet
step "propose charter v2: the gate fails" improve live check_proposal \
  propose st_triage --charter "$example/charter-v2.json"
step "the live charter stays ready (v1)" improve live check_still_ready steward show st_triage
step "correct the live run" improve live check_run_corrected run correct "${run_id:-unknown}" \
  --choice refunds --note "Duplicate-charge refunds go to the refunds queue."
step "the run became a case" improve live check_new_case casebook list --steward st_triage
step "the note became a memory" improve live check_remembered memory st_triage
step "retract the note" improve live check_retracted retract "${memory_id:-unknown}" \
  --reason "Billing owns refunds."
step "later runs no longer recall it" improve live check_forgotten memory st_triage
step "editor proposal: the gate passes" improve live check_editor_proposal \
  propose st_triage --charter "$work/edited.json"
step "it is ready to go live" improve live check_readiness readiness "${proposal_id:-unknown}"
step "MSG-203: a crew drafts the reply" crew live check_crew \
  run st_triage --input "New message MSG-203: Damaged order, please refund"
step "the crew child only proposes" crew live check_child run show "${crew_child:-unknown}"
step "import inbox history: 24 new cases" history rehearsal check_history \
  history import st_triage --file "$example/history-export.json"
step "rehearse with history: 28 of 33" history rehearsal check_history_rehearsal \
  rehearse st_triage
step "review queue: MSG-113 disagrees" history rehearsal check_review_queue review st_triage
step "agree with MSG-110" history rehearsal check_reviewed \
  review st_triage --case hist-MSG-110 --verdict agree
step "corrections and agreements became checks" history rehearsal check_checks \
  checks st_triage
step "onboarding: history imported, review next" history rehearsal check_onboarding \
  steward onboarding st_triage
step "go-live gate: what is still missing" history rehearsal check_gate steward gate st_triage
step "trajectories: drafts are not graded" history live check_trajectories \
  steward trajectories st_triage
step "metrics: routed within 1 h vs target" metrics live check_metric_statuses \
  steward metrics st_triage
step "grow the casebook from its runs" history rehearsal check_casebook_build \
  casebook build st_triage
step "a steward reading the inbox binding" history setup check_history_steward \
  steward create --charter "$work/history.json"
step "import 40 past messages from it" history setup check_binding_history \
  history import st_history --binding inbox
step "a steward on a real folder connector" history setup check_folder_steward \
  steward create --charter "$work/folder.json"
step "import its history with --from" history setup check_folder_history \
  history import st_folder --from inbox
step "sam asks; a run answers" connect live check_asked \
  message st_triage "Which refunds are still waiting?" --as person:sam
step "sam's correction is kept as memory" connect live check_message_kept \
  message st_triage "Refund questions about gift cards go to billing." --as person:sam \
  --intent correct
step "report: what it would send now" connect live check_report report show st_triage
step "send the report" connect live check_report report send st_triage
start_long_run
step "steward live: the long run is running" abort live check_live_running \
  steward live st_triage
step "abort a long run from another process" abort live check_abort_requested \
  run abort "${long_run:-unknown}" --reason "the customer withdrew the request"
# The aborted `arya run` exits non-zero; its end is checked through `run show`.
if [ -n "${long_pid:-}" ]; then wait "$long_pid" 2>/dev/null || true; fi
step "it stopped and executed nothing" abort live check_aborted run show "${long_run:-unknown}"
step "policy: who may approve each action" governance setup check_policy \
  steward policy st_triage
step "undo: the live run's label can be undone" governance live check_undo_options \
  undo "${run_id:-unknown}"
step "undo it: unlabel waits for approval" governance live check_undone \
  undo "${run_id:-unknown}" "${undo_action:-unknown}" --reason "wrong queue"
step "retention: triage keeps 90 days" governance setup check_retention \
  retention --steward st_triage --days 90
step "export the triage steward, signed" governance live check_exported \
  export st_triage --signed --out "$work/export"
step "the export checks on its own" governance live check_export_verified \
  export verify "$work/export"
# A copy with one changed byte in its events must no longer check.
cp -R "$work/export" "$work/tampered" 2>/dev/null &&
  sed -i '' 's/st_triage/st_triagf/' "$work/tampered/events.jsonl" 2>/dev/null || true
refused_step "a changed byte fails the check" governance live "does not check" \
  export verify "$work/tampered"
# Import into a fresh home: point `arya` at it for one step.
"$bin/arya" --home "$work/imported" --json init >/dev/null 2>&1 || true
source_home=$home
home="$work/imported"
step "import it into a fresh home" governance live check_steward_imported \
  import "$work/export"
home=$source_home
step "steward live: nothing running now" abort live check_live_idle steward live st_triage
script_step "docs-only publish skips the build" publish etc/scripts/test-publish.sh docs-only
step "verify the ledger" setup - check_verify ledger verify

case "$state" in
  ok) echo "e2e: ok ($n steps)" ;;
  pending) echo "e2e: pending; each PENDING step above names the missing piece"; exit 2 ;;
  *) echo "e2e: FAILED"; exit 1 ;;
esac
