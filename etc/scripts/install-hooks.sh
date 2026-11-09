#!/usr/bin/env bash
# Install pre-commit and commit-msg hooks into the shared git dir, so one install
# covers every worktree. Hooks run the worktree's etc/scripts/tidy.sh and fall back
# to a copy installed next to them for worktrees that predate the script.
# Never sets core.hooksPath; a global dispatcher may chain to these hooks.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

hooks="$(cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
mkdir -p "$hooks"
cp etc/scripts/tidy.sh "$hooks/arya-tidy.sh"
chmod +x "$hooks/arya-tidy.sh"

write_hook() {
  local name=$1 args=$2
  cat > "$hooks/$name" <<HOOK
#!/usr/bin/env bash
# Installed by etc/scripts/install-hooks.sh.
set -euo pipefail
script="\$(git rev-parse --show-toplevel)/etc/scripts/tidy.sh"
[ -x "\$script" ] || script="\$(git rev-parse --git-common-dir)/hooks/arya-tidy.sh"
exec "\$script" $args
HOOK
  chmod +x "$hooks/$name"
}
write_hook pre-commit ''
write_hook commit-msg '--commit-msg "$1"'
echo "install-hooks: installed pre-commit and commit-msg in $hooks"
