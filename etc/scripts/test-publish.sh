#!/usr/bin/env bash
# Tests etc/scripts/publish.sh against throwaway repositories: a bare origin, the lane's clone,
# and another lane's clone that pushes first. A stub `just` records what publish runs and
# "formats" by rewriting `fmt-me.swift`. Commits follow your git signing settings, so the
# pushes pass the same hooks as real ones. Run with `just test-scripts`.
#
#   test-publish.sh [SCENARIO]   all scenarios, or one: code, docs-only, dirty, fmt, fmt-race, race,
#                                conflict, lock (`just e2e` runs docs-only)
set -euo pipefail
publish="$(cd "$(dirname "$0")" && pwd)/publish.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/arya-test-publish.XXXXXX")
trap 'rm -rf "$root"' EXIT
failures=0
only=${1:-}
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

check() { # check DESCRIPTION COMMAND...: report one expectation
  if "${@:2}"; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1"
    sed 's/^/        /' "$root/out" 2>/dev/null || true
    failures=$((failures + 1))
  fi
}

# The stub `just`: logs its arguments; `fmt` normalizes fmt-me.swift if it exists.
cat >"$root/just" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$ARYA_TEST_JUST_LOG"
if [ "${1:-}" = fmt ] && [ -f fmt-me.swift ]; then printf 'let formatted = 1\n' >fmt-me.swift; fi
# An edit that lands while `just fmt` runs (the fmt-race scenario).
if [ "${1:-}" = fmt ] && [ -n "${ARYA_TEST_FMT_RACE:-}" ]; then echo racing >>docs/x.md; fi
exit 0
EOF
chmod +x "$root/just"

# fresh: a new origin with one commit, and clones `lane` and `other`.
fresh() {
  rm -rf "$root/origin.git" "$root/lane" "$root/other" "$root/seed"
  git init -q --bare -b main "$root/origin.git"
  git clone -q "$root/origin.git" "$root/seed" 2>/dev/null
  (cd "$root/seed" && printf 'one\ntwo\n' >code.swift && mkdir docs && echo log >docs/x.md &&
    git add -A && git commit -q -m base && git push -q origin HEAD:main)
  git clone -q "$root/origin.git" "$root/lane"
  git clone -q "$root/origin.git" "$root/other"
  : >"$root/just.log"
}

publish() { # publish in the lane clone; output in $root/out
  (cd "$root/lane" && ARYA_PUBLISH_JUST="$root/just" ARYA_PUBLISH_SIGN="" \
    ARYA_TEST_JUST_LOG="$root/just.log" bash "$publish" Tests) >"$root/out" 2>&1
}
commit() { (cd "$root/$1" && git add -A && git commit -q -m "$2"); }
origin_has() { # (no `grep -q` on a pipe: under pipefail, its early exit fails git log)
  git --git-dir="$root/origin.git" log --format=%s main | grep -x "$1" >/dev/null
}
clean() { [ -z "$(cd "$root/lane" && git status --porcelain --untracked-files=no)" ]; }
not_rebasing() { [ ! -d "$root/lane/.git/rebase-merge" ] && [ ! -d "$root/lane/.git/rebase-apply" ]; }
said() { grep -q "$1" "$root/out"; }
ran() { grep -qx "$1" "$root/just.log"; }
fails() { ! publish; }
not_ran() { ! ran "$1"; }
origin_lacks() { ! origin_has "$1"; }

if want code; then
  echo "publish: a code change runs the full check and pushes"
  fresh
  echo three >>"$root/lane/code.swift" && commit lane "feat: three"
  check "exits 0" publish
  check "pushed" origin_has "feat: three"
  check "ran just ci" ran ci

fi

if want docs-only; then
  echo "publish: a docs-only change skips the build"
  fresh
  echo more >>"$root/lane/docs/x.md" && commit lane "docs: more"
  check "exits 0" publish
  check "pushed" origin_has "docs: more"
  check "ran just tidy" ran tidy
  check "did not run just ci" not_ran ci

fi

if want dirty; then
  echo "publish: a dirty tree fails early and is left alone"
  fresh
  echo three >>"$root/lane/code.swift" && commit lane "feat: three"
  echo wip >>"$root/lane/code.swift"
  check "exits non-zero" fails
  check "says why" said "uncommitted changes"
  check "keeps the edit" grep -q wip "$root/lane/code.swift"
  check "pushed nothing" origin_lacks "feat: three"

fi

if want fmt; then
  echo "publish: formatting from just fmt is committed on its own"
  fresh
  printf 'let   formatted=1\n' >"$root/lane/fmt-me.swift" && commit lane "feat: add fmt-me"
  check "exits 0" publish
  check "pushed the change" origin_has "feat: add fmt-me"
  check "pushed a format commit" origin_has "style: apply swift format"
  check "tree is clean" clean

fi

if want fmt-race; then
  echo "publish: an edit racing just fmt is never committed"
  fresh
  printf 'let   formatted=1\n' >"$root/lane/fmt-me.swift" && commit lane "feat: add fmt-me"
  export ARYA_TEST_FMT_RACE=1
  check "exits non-zero" fails
  unset ARYA_TEST_FMT_RACE
  check "says why" said "files changed during the publish"
  check "keeps the edit uncommitted" grep -q racing "$root/lane/docs/x.md"
  check "pushed nothing" origin_lacks "feat: add fmt-me"

fi

if want race; then
  echo "publish: a push race rebases and pushes both sides"
  fresh
  echo three >>"$root/lane/code.swift" && commit lane "feat: three"
  echo other >"$root/other/other.swift" && commit other "feat: other"
  (cd "$root/other" && git push -q origin HEAD:main)
  check "exits 0" publish
  check "kept the other lane's commit" origin_has "feat: other"
  check "pushed ours" origin_has "feat: three"

fi

if want conflict; then
  echo "publish: a rebase conflict aborts and leaves the branch as it was"
  fresh
  sed -i.bak 's/two/mine/' "$root/lane/code.swift" && rm "$root/lane/code.swift.bak"
  commit lane "feat: mine"
  before=$(cd "$root/lane" && git rev-parse HEAD)
  sed -i.bak 's/two/theirs/' "$root/other/code.swift" && rm "$root/other/code.swift.bak"
  commit other "feat: theirs" && (cd "$root/other" && git push -q origin HEAD:main)
  check "exits non-zero" fails
  check "names the file" said "rebase conflict in code.swift"
  check "no rebase in progress" not_rebasing
  check "tree is clean" clean
  check "branch unchanged" test "$(cd "$root/lane" && git rev-parse HEAD)" = "$before"

fi

if want lock; then
  echo "publish: a stale index.lock is removed"
  fresh
  echo three >>"$root/lane/code.swift" && commit lane "feat: three"
  : >"$root/lane/.git/index.lock"
  check "exits 0" publish
  check "says it removed the lock" said "removed a stale"
  check "pushed" origin_has "feat: three"
fi

if [ "$failures" -gt 0 ]; then
  echo "test-publish: $failures failed"
  exit 1
fi
echo "test-publish: ok"
