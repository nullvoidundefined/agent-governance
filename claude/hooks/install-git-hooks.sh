#!/usr/bin/env bash
# Installs the tracked git-side hooks that .git/ cannot carry itself.
#
# Replaces SETUP.md step 3's "write a bash script that runs both suites": a
# prose description of a script drifts from the script, and in the 2026-09-04
# audit the file it described did not exist at all in the checkout.
#
#   bash ~/.claude/hooks/install-git-hooks.sh            # install into ~/.claude
#   bash ~/.claude/hooks/install-git-hooks.sh /path/repo # or another checkout
#
# Refuses to clobber an existing pre-push that this script did not write, so a
# repo with its own hook chain is never silently replaced.
set -euo pipefail

REPO="${1:-$HOME/.claude}"
SAMPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-push.sample"
MARKER="Git pre-push hook for the ~/.claude repo"

[ -f "$SAMPLE" ] || { echo "install-git-hooks: $SAMPLE is missing." >&2; exit 1; }
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "install-git-hooks: $REPO is not a git work tree." >&2; exit 1;
}

HOOK_DIR="$(git -C "$REPO" rev-parse --git-path hooks)"
case "$HOOK_DIR" in
  /*) ;;
  *) HOOK_DIR="$REPO/$HOOK_DIR" ;;
esac
mkdir -p "$HOOK_DIR"
TARGET="$HOOK_DIR/pre-push"

if [ -f "$TARGET" ] && ! grep -q "$MARKER" "$TARGET"; then
  echo "install-git-hooks: $TARGET exists and was not written by this script." >&2
  echo "Merge it by hand, or move it aside and re-run." >&2
  exit 1
fi

cp "$SAMPLE" "$TARGET"
chmod +x "$TARGET"
echo "install-git-hooks: installed $TARGET"

HOOKS_PATH=$(git -C "$REPO" config --get core.hooksPath || true)
if [ -n "$HOOKS_PATH" ]; then
  echo "install-git-hooks: note, core.hooksPath is set to '$HOOKS_PATH'; verify the hook you just installed is the one git will run (R-107)." >&2
fi
