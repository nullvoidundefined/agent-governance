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
# repo with its own hook chain is never silently replaced. The single exception
# is this repo's own superseded hook, which is identifiable by its own header:
# an identified predecessor is an upgrade, not a clobber, so it is replaced in
# place and backed up. Anything unrecognised still stops the script.
set -euo pipefail

REPO="${1:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$SCRIPT_DIR/pre-push.sample"
MARKER="Git pre-push hook for the ~/.claude repo"
# The unversioned hook this script replaced (SETUP.md, 2026-07-31 audit P1).
LEGACY_MARKER="Unversioned git pre-push hook for the ~/.claude repo"

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

ACTION="installed"
BACKUP=""

if [ -f "$TARGET" ] && ! grep -q "$MARKER" "$TARGET"; then
  if grep -q "$LEGACY_MARKER" "$TARGET"; then
    BACKUP="$TARGET.legacy.bak"
    cp "$TARGET" "$BACKUP"
    ACTION="upgraded"
  else
    echo "install-git-hooks: $TARGET exists and was not written by this script." >&2
    echo "Merge it by hand, or move it aside and re-run:" >&2
    echo "  mv \"$TARGET\" \"$TARGET.bak\" && bash \"$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")\" \"$REPO\"" >&2
    exit 1
  fi
fi

cp "$SAMPLE" "$TARGET"
chmod +x "$TARGET"
echo "install-git-hooks: $ACTION $TARGET"
if [ -n "$BACKUP" ]; then
  echo "install-git-hooks: previous hook saved to $BACKUP"
fi

HOOKS_PATH=$(git -C "$REPO" config --get core.hooksPath || true)
if [ -n "$HOOKS_PATH" ]; then
  echo "install-git-hooks: note, core.hooksPath is set to '$HOOKS_PATH'; verify the hook you just installed is the one git will run (R-107)." >&2
fi
