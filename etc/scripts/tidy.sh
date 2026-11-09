#!/usr/bin/env bash
# Repository hygiene: formatting, line length, secrets and private data, a local
# denylist, forbidden files, and no package dependencies. Run with `just tidy`.
#
#   tidy.sh                     check the repository (tracked and staged files)
#   tidy.sh --commit-msg FILE   check a commit message (used by the commit-msg hook)
#
# Hits print as file:line only; matched text and denylist contents are never shown.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
common_dir=$(git rev-parse --git-common-dir)
deny_ci="$common_dir/info/denylist"
deny_cs="$common_dir/info/denylist-case-sensitive"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Generic secret and private-data patterns, assembled so this file does not match itself.
p_home='/Us''ers/[A-Za-z]|/ho''me/[a-z][a-z0-9_-]*/'
p_keys='BEGIN [A-Z ]*PRIV''ATE KEY|AK''IA[0-9A-Z]{16}|gh[pousr]''_[A-Za-z0-9]{30,}'
p_keys="$p_keys|xox[abprs]""-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}"
p_mail='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
p_mail_ok='noreply|no-reply|@example\.(com|org|net)'

# report LABEL HITS: print the hits under a label and mark the run failed.
report() {
  local label=$1 hits=$2
  if [ -n "$hits" ]; then
    echo "tidy: $label:"
    echo "$hits"
    fail=1
  fi
}

# Strip blank and comment lines from a denylist into a pattern file. Fails on bad EREs.
load_denylist() {
  local src=$1 dst=$2 flags=$3
  [ -f "$src" ] || return 1
  grep -vE '^[[:space:]]*(#|$)' "$src" > "$dst" || true
  [ -s "$dst" ] || return 1
  local rc=0
  grep $flags -f "$dst" /dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "tidy: $(basename "$src") has an invalid pattern"
    fail=1
    return 1
  fi
}

have_ci=0
have_cs=0
load_denylist "$deny_ci" "$tmp/deny-ci" '-iE' && have_ci=1
load_denylist "$deny_cs" "$tmp/deny-cs" '-E' && have_cs=1

# scan_text FILE...: denylist, secret, and email checks. Prints file:line only.
scan_text() {
  [ "$#" -gt 0 ] || return 0
  if [ "$have_ci" -eq 1 ]; then
    report "denylisted term" "$(grep -HnIiE -f "$tmp/deny-ci" -- "$@" 2>/dev/null \
      | cut -d: -f1,2 || true)"
  fi
  if [ "$have_cs" -eq 1 ]; then
    report "denylisted term (case-sensitive)" "$(grep -HnIE -f "$tmp/deny-cs" -- "$@" \
      2>/dev/null | cut -d: -f1,2 || true)"
  fi
  local secret_files=()
  local f
  for f in "$@"; do
    [ "$f" = etc/scripts/tidy.sh ] || secret_files+=("$f")
  done
  [ "${#secret_files[@]}" -gt 0 ] || return 0
  report "possible secret or private path" "$(grep -HnIE "$p_home|$p_keys" -- \
    "${secret_files[@]}" 2>/dev/null | cut -d: -f1,2 || true)"
  report "email address" "$(grep -HnIE "$p_mail" -- "${secret_files[@]}" 2>/dev/null \
    | grep -vE "$p_mail_ok" | cut -d: -f1,2 || true)"
}

if [ "${1:-}" = "--commit-msg" ]; then
  msg=${2:?usage: tidy.sh --commit-msg FILE}
  # Drop git's comment lines and everything below the scissors line.
  sed -e '/^# -* >8 -*$/,$d' -e '/^#/d' "$msg" > "$tmp/COMMIT_MSG"
  cd "$tmp"
  scan_text COMMIT_MSG
  # Co-author trailers can carry identities and emails; this repository allows none.
  report "co-author trailer (not allowed)" "$(grep -HniE '^[[:space:]]*co-authored-by:' \
    COMMIT_MSG | cut -d: -f1,2 || true)"
  [ "$fail" -eq 0 ] || echo "tidy: commit message rejected"
  exit "$fail"
fi

# Tracked and staged files that exist in the working tree.
files=()
while IFS= read -r -d '' f; do
  [ -f "$f" ] && files+=("$f")
done < <(git ls-files -c -z)

# 1. swift format lint (skipped if the toolchain lacks it).
swift_dirs=()
for d in Package.swift Sources Tests; do
  [ -e "$d" ] && swift_dirs+=("$d")
done
if [ "${#swift_dirs[@]}" -gt 0 ]; then
  if swift format --version >/dev/null 2>&1; then
    if ! swift format lint --strict --parallel --recursive --configuration etc/swift-format.json \
      "${swift_dirs[@]}"; then
      echo "tidy: swift format lint failed; run \`just fmt\`"
      fail=1
    fi
  else
    echo "tidy: swift format unavailable, skipping format lint"
  fi
fi

# 2. Swift lines <= 100 columns.
swift_files=()
for f in ${files[@]+"${files[@]}"}; do
  case "$f" in *.swift) swift_files+=("$f") ;; esac
done
if [ "${#swift_files[@]}" -gt 0 ]; then
  report "lines over 100 columns" "$(awk 'length > 100 { print FILENAME ":" FNR }' \
    "${swift_files[@]}")"
fi

# 3-4. Secrets, emails, and the local denylists.
scan_text ${files[@]+"${files[@]}"}

# 6. Forbidden files.
report "files that must never be committed" "$(git ls-files -c \
  | grep -E '(^|/)\.env(\..*)?$|^\.pi/|^\.claude/' || true)"

# 6b. CI is staged in etc/ci; the push credential cannot write workflows.
report "workflow files (stage CI in etc/ci instead)" "$(git ls-files -c \
  | grep -E '^\.github/workflows/' || true)"

# 6c. CLAUDE.md is a byte-identical copy of AGENTS.md.
if [ -f AGENTS.md ] && ! cmp -s AGENTS.md CLAUDE.md; then
  echo "tidy: CLAUDE.md differs from AGENTS.md; run \`cp AGENTS.md CLAUDE.md\`"
  fail=1
fi

# 6d. Shell scripts parse.
for f in ${files[@]+"${files[@]}"}; do
  case "$f" in
    *.sh) bash -n "$f" 2>/dev/null || report "shell syntax error" "$f" ;;
  esac
done

# 7. No package dependencies.
if [ -f Package.swift ] && grep -qE '\.package[[:space:]]*\(' Package.swift; then
  echo "tidy: Package.swift must have no package dependencies"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "tidy: ok"
exit "$fail"
