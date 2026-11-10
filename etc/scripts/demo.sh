#!/usr/bin/env bash
# Seed the busy demo home at .build/demo-home. Run with `just demo`; look at it with
# `just snapshot` (offscreen renders). It never opens the app window (decision 0038).
#
# `arya-demo` (Sources/AryaDemo) writes the whole home in one process: the example stewards
# from etc/examples (triage, refund follow-up, weekly digest) and eight generated ones across
# departments from etc/examples/templates, with weeks of rhythmic history, approvals decided
# and waiting, messages from people, proposals, memory, and today's runs. A person's last look
# lands about two hours before the newest activity (`app/visits.json`).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

case "${1:-}" in
  --no-open | "") ;;
  *) echo "usage: demo.sh" >&2; exit 64 ;;
esac

home="$PWD/.build/demo-home"
bin=$(swift build --show-bin-path)
# Build only when a source is newer than the seeder; a build may wait for a CI slot.
if [ ! -x "$bin/arya-demo" ] || [ ! -x "$bin/arya-fake-adapter" ] || [ ! -x "$bin/arya" ] ||
  [ -n "$(find Sources Package.swift -newer "$bin/arya-demo" -print -quit)" ]; then
  echo "demo: building"
  log=$(mktemp "${TMPDIR:-/tmp}/arya-demo.XXXXXX")
  trap 'rm -f "$log"' EXIT
  if ! just build >"$log" 2>&1; then
    cat "$log"
    echo "demo: build failed"
    exit 1
  fi
fi
"$bin/arya-demo" "$home" "$PWD/etc/examples"
echo "demo: seeded $home; render it with \`just snapshot\` (offscreen, no window)"
