#!/usr/bin/env bash
# Verifies that the COMMITTED hash manifest is closed in both directions
# against the installed enforcement surface (R-203, 2026-09-17 audit P1-2).
#
# The SessionStart guard already reports drift, but only to whoever starts a
# session, and only after the fact: the manifest could be committed naming a
# file that no longer exists (which is what four entries did between the
# 2026-09-17 kebab-casing rename and the commit that deleted them), or omitting
# a file it should cover, and nothing failed. In CI `$HOME/.claude` is a symlink
# to the checkout, so the tree this fixture validates is the tree git carries
# and a stale manifest is a red check rather than a warning nobody reads.
#
# Forward closure: every manifest entry names a file that exists.
# Reverse closure: every file the guard covers appears in the manifest.
# Floor: the manifest is not empty or truncated, so this fixture cannot pass
# by inspecting nothing (the failure mode P1-4 found in another fixture).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CLAUDE_DIR="${CLAUDE_INTEGRITY_ROOT:-$CLAUDE_HARNESS_ROOT}"
HASH_FILE="$CLAUDE_DIR/enforce/hook-hashes.txt"
HOOK="$CLAUDE_DIR/hooks/hook-integrity-check.sh"
MIN_ENTRIES=60

fail=0

if [ ! -f "$HASH_FILE" ]; then
  echo "FAIL: no hash manifest at $HASH_FILE; the R-203 guard has nothing to compare against"
  exit 1
fi
if [ ! -x "$HOOK" ] && [ ! -f "$HOOK" ]; then
  echo "FAIL: no hook-integrity-check.sh at $HOOK"
  exit 1
fi

ENTRY_COUNT=$(grep -c . "$HASH_FILE" || true)
if [ "$ENTRY_COUNT" -lt "$MIN_ENTRIES" ]; then
  echo "FAIL: manifest holds $ENTRY_COUNT entries, expected at least $MIN_ENTRIES; it is empty, truncated, or not this repo's manifest, so this fixture proved nothing"
  fail=1
fi

# Forward: a manifest line whose path is gone. Reported as its own failure
# rather than as generic drift, because the fix differs: a phantom entry means
# rerun --update, while a content mismatch means investigate the file.
while read -r _hash path; do
  [ -n "${path:-}" ] || continue
  [ -e "$CLAUDE_DIR/$path" ] || {
    echo "FAIL: manifest names $path, which does not exist under $CLAUDE_DIR (rename or deletion without a --update)"
    fail=1
  }
done < "$HASH_FILE"

# Reverse: a covered file the manifest does not name. The covered set is read
# out of the guard itself rather than restated here, so the two cannot drift
# apart; a second copy of the glob list is exactly the enumeration problem this
# fixture exists to close.
COVERED=$(sed -n 's/^ *files=\$({ ls \(.*\) 2>\/dev\/null.*/\1/p' "$HOOK")
if [ -z "$COVERED" ]; then
  echo "FAIL: could not read the covered-file globs out of $HOOK; its compute_hashes shape changed and this fixture is now blind"
  exit 1
fi

MANIFEST_PATHS=$(awk '{print $NF}' "$HASH_FILE" | sort -u)
# shellcheck disable=SC2086
ON_DISK=$( (cd "$CLAUDE_DIR" && { ls $COVERED 2>/dev/null || true; }) | sort -u)
if [ -z "$ON_DISK" ]; then
  echo "FAIL: the guard's globs matched no files under $CLAUDE_DIR; the tree is wrong or empty"
  exit 1
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  # A here-string, not a pipe: under pipefail, grep -q exiting at its first
  # match while printf still writes this ~10KB list fails the pipeline and
  # reports a present path as absent (PR #42 CI, 2026-09-18).
  grep -qxF "$path" <<< "$MANIFEST_PATHS" || {
    echo "FAIL: $path is covered by the R-203 guard but absent from the manifest (new file without a --update)"
    fail=1
  }
done <<< "$ON_DISK"

# Content: the guard's own comparison, so a tampered or edited file fails here
# too and not only at the next session start.
DRIFT=$(echo '{}' | CLAUDE_INTEGRITY_ROOT="$CLAUDE_DIR" bash "$HOOK" 2>/dev/null | grep -c 'do NOT match' || true)
if [ "${DRIFT:-0}" -gt 0 ]; then
  echo "FAIL: the guard reports content drift between the installed tree and the committed manifest; run hooks/hook-integrity-check.sh --update and commit the manifest with the change"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "hook-hashes-closure.test.sh PASS ($ENTRY_COUNT entries, $(printf '%s\n' "$ON_DISK" | grep -c .) covered files)"
exit "$fail"
