#!/usr/bin/env bash
# Render every key app state offscreen to .build/snapshots (no window; decision 0038), from a
# copy of the current demo home with one run in progress: a live lead follow-up run whose
# process holds the run's lease while the snapshot tests render, streaming tool calls. The copy
# keeps .build/demo-home pristine, since the stopped live run is recorded as interrupted.
#
#   snapshot.sh SWIFT-TEST-ARGS...   (the Justfile passes the swift flags and job count)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

etc/scripts/demo-current.sh
home="$PWD/.build/snapshot-home"
rm -rf "$home" .build/snapshots
cp -cR .build/demo-home "$home" 2>/dev/null || cp -R .build/demo-home "$home"
bin=$(swift build --show-bin-path)
"$bin/arya" --home "$home" run st_lead_follow_up \
  --input "LEAD-LIVE: Pricing question from a 200-seat team" >/dev/null 2>&1 &
live=$!
trap 'kill "$live" 2>/dev/null || true; wait "$live" 2>/dev/null || true' EXIT
ARYA_SNAPSHOT_DIR="$PWD/.build/snapshots" ARYA_SNAPSHOT_HOME="$home" \
  etc/scripts/slot.sh swift test "$@" --filter SnapshotTests
ls .build/snapshots
