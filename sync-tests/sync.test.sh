#!/usr/bin/env bash
# sync.test.sh: verifies sync.sh copies each folder into its target, leaves
# each tool's runtime-only state untouched, refuses on invalid JSON without a
# partial write, and is idempotent. Every target is a temp dir via the
# SYNC_*_HOME overrides, so this never touches a real ~/.claude, ~/.cursor,
# or ~/.codex.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)

mkdir -p "$TMP/repo/claude" "$TMP/repo/cursor" "$TMP/repo/codex"
mkdir -p "$TMP/live/claude" "$TMP/live/cursor" "$TMP/live/codex"
cp "$REPO_ROOT/sync.sh" "$TMP/repo/sync.sh"; chmod +x "$TMP/repo/sync.sh"

echo "rule content" > "$TMP/repo/claude/CLAUDE.md"
echo '{"a":1}' > "$TMP/repo/claude/settings.json"

run_sync() {
  SYNC_CLAUDE_HOME="$TMP/live/claude" SYNC_CURSOR_HOME="$TMP/live/cursor" SYNC_CODEX_HOME="$TMP/live/codex" \
    "$TMP/repo/sync.sh"
}

run_sync >/dev/null
[ -f "$TMP/live/claude/CLAUDE.md" ] || { echo "FAIL: CLAUDE.md not synced"; exit 1; }
diff "$TMP/repo/claude/CLAUDE.md" "$TMP/live/claude/CLAUDE.md" >/dev/null || { echo "FAIL: synced content differs"; exit 1; }

mkdir -p "$TMP/live/claude/sessions"; echo "keep me" > "$TMP/live/claude/sessions/marker.txt"
run_sync >/dev/null
[ -f "$TMP/live/claude/sessions/marker.txt" ] || { echo "FAIL: sync deleted excluded runtime state"; exit 1; }

cp "$TMP/live/claude/CLAUDE.md" "$TMP/live/claude/CLAUDE.md.before"
echo "{not json" > "$TMP/repo/claude/settings.json"
if run_sync >/dev/null 2>"$TMP/err.log"; then echo "FAIL: expected sync to refuse on invalid JSON"; exit 1; fi
grep -q "REFUSED" "$TMP/err.log" || { echo "FAIL: expected a REFUSED message"; exit 1; }
diff "$TMP/live/claude/CLAUDE.md" "$TMP/live/claude/CLAUDE.md.before" >/dev/null || { echo "FAIL: partial write happened despite refusal"; exit 1; }
echo '{"a":1}' > "$TMP/repo/claude/settings.json"

run_sync >/dev/null
BEFORE=$(find "$TMP/live/claude" -type f | sort | xargs -I{} shasum {} | shasum)
run_sync >/dev/null
AFTER=$(find "$TMP/live/claude" -type f | sort | xargs -I{} shasum {} | shasum)
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: second sync run was not idempotent"; exit 1; }

rm -rf "$TMP"
echo "sync.test.sh PASS"
