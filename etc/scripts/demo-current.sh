#!/usr/bin/env bash
# Make .build/demo-home current for `just snapshot`: reseed it when it is missing, on a new
# day (its history is relative to today), or when any seed input (etc/examples/**,
# etc/scripts/demo.sh, Sources/AryaDemo/**) changed since it was seeded, else reuse it. The
# seed stamp is a hash of those inputs and the date, kept in the home.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

home=.build/demo-home
stamp="$home/.seed"
want=$({ date -u +%F; find etc/scripts/demo.sh etc/examples Sources/AryaDemo -type f -print0 |
  sort -z | xargs -0 shasum -a 256; } | shasum -a 256 | cut -d' ' -f1)
if [ -d "$home" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
  echo "demo home: reused (current)"
  exit 0
fi
etc/scripts/demo.sh --no-open >/dev/null
echo "$want" >"$stamp"
echo "demo home: reseeded"
