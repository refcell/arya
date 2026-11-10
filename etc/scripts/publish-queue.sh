# The publish queue (sourced by publish.sh): lanes publish one at a time, first come first
# served. Each publish takes a ticket, a file `<epoch seconds>-<pid>` holding the lane name in
# <git common dir>/arya-publish-queue (ARYA_PUBLISH_QUEUE), waits until it is the oldest live
# ticket, and removes it on exit. A ticket whose process is gone, or untouched for 25 minutes
# (ARYA_PUBLISH_TICKET_MAX seconds; waiting lanes touch theirs on every poll, so this bounds
# the turn of a hung publish), is expired and removed by whoever sees it. Waiting polls
# every 15 s (ARYA_PUBLISH_POLL) and prints the position when it changes.

queue=${ARYA_PUBLISH_QUEUE:-$(cd "$(git rev-parse --git-common-dir)" && pwd)/arya-publish-queue}
queue_poll=${ARYA_PUBLISH_POLL:-15}
ticket_max=${ARYA_PUBLISH_TICKET_MAX:-1500}
ticket=""

# live_tickets: the live tickets, oldest first, after removing expired ones.
live_tickets() {
  local file name pid now
  now=$(date +%s)
  for file in "$queue"/*-*; do
    [ -e "$file" ] || continue
    name=${file##*/}
    pid=${name##*-}
    if ! kill -0 "$pid" 2>/dev/null ||
      [ $((now - $(stat -f %m "$file" 2>/dev/null || echo 0))) -gt "$ticket_max" ]; then
      [ "$file" = "$ticket" ] || rm -f -- "$file"
      continue
    fi
    printf '%s\n' "$name"
  done | sort -t- -k1,1n -k2,2n
}

take_ticket() {
  mkdir -p "$queue"
  ticket="$queue/$(date +%s)-$$"
  basename "$(dirname "$PWD")" >"$ticket"
}

wait_for_turn() {
  local mine tickets position last="" ahead
  mine=${ticket##*/}
  while :; do
    touch "$ticket" # still here (a crashed lane's ticket expires by pid)
    tickets=$(live_tickets)
    position=$(printf '%s\n' "$tickets" | grep -n -x -- "$mine" | cut -d: -f1)
    [ "${position:-1}" = 1 ] && break
    if [ "$position" != "$last" ]; then
      ahead=$(head -n 1 "$queue/$(printf '%s\n' "$tickets" | head -n 1)" 2>/dev/null || true)
      say "queued: position $position of $(printf '%s\n' "$tickets" | wc -l | tr -d ' ')" \
        "(publishing: ${ahead:-unknown})"
      last=$position
    fi
    sleep "$queue_poll"
  done
  [ -z "$last" ] || say "queue: your turn"
}
