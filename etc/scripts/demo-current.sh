#!/usr/bin/env bash
# Make .build/demo-home current for `just snapshot`: reseed it when it is missing, on a new
# day (its history is relative to today), or when any seed input (etc/examples/**,
# etc/scripts/demo.sh, Sources/AryaDemo/**, Sources/Arya/Seeding.swift) changed since it was
# seeded, else reuse it. The seed stamp is a hash of those inputs and the date, kept in the home.
#
# Worktrees of one clone share seeded homes: a fresh seed is copied to
# <git common dir>/arya-demo-homes/<stamp>, and a worktree with the same stamp copies it from
# there instead of seeding (about 13 min under load), moving its adapter paths to its own
# home and build. Seeds older than two days are removed from that cache.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

home=.build/demo-home
stamp="$home/.seed"
want=$({ date +%F; find etc/scripts/demo.sh etc/examples Sources/AryaDemo \
  Sources/Arya/Seeding.swift -type f -print0 | sort -z | xargs -0 shasum -a 256; } |
  shasum -a 256 | cut -d' ' -f1)
if [ -d "$home" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
  echo "demo home: reused (current)"
  exit 0
fi

shared="$(cd "$(git rev-parse --git-common-dir)" && pwd)/arya-demo-homes"
copy() { cp -cR "$1" "$2" 2>/dev/null || cp -R "$1" "$2"; }

if [ -f "$shared/$want/.seed" ]; then
  rm -rf "$home" "$home.tmp"
  copy "$shared/$want" "$home.tmp"
  # .paths: the seeding worktree's home and build directory, one per line.
  { read -r from_home; read -r from_bin; } <"$home.tmp/.paths"
  bin=$(swift build --show-bin-path 2>/dev/null)
  sed -i '' -e "s|$from_home|$PWD/$home|g" -e "s|$from_bin|$bin|g" "$home.tmp/adapters.json"
  printf '%s\n%s\n' "$PWD/$home" "$bin" >"$home.tmp/.paths"
  mv "$home.tmp" "$home"
  echo "demo home: copied from the shared seed"
  exit 0
fi

etc/scripts/demo.sh --no-open >/dev/null
printf '%s\n%s\n' "$PWD/$home" "$(swift build --show-bin-path 2>/dev/null)" >"$home/.paths"
echo "$want" >"$stamp"
mkdir -p "$shared"
find "$shared" -mindepth 1 -maxdepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null || true
if [ ! -e "$shared/$want" ]; then
  copy "$home" "$shared/$want.$$" && mv "$shared/$want.$$" "$shared/$want" 2>/dev/null ||
    rm -rf "$shared/$want.$$"
fi
echo "demo home: reseeded"
