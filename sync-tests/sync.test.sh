#!/usr/bin/env bash
# sync.test.sh: verifies sync.sh copies each folder into its target, leaves
# each tool's runtime-only state untouched, refuses on invalid JSON without a
# partial write, is idempotent, syncs only git-tracked source content (never
# untracked/gitignored local state such as node_modules), and mirrors tracked
# deletions. Every target is a temp dir via the SYNC_*_HOME overrides, so this
# never touches a real ~/.claude, ~/.cursor, or ~/.codex.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)

mkdir -p "$TMP/repo/claude" "$TMP/repo/cursor" "$TMP/repo/codex"
mkdir -p "$TMP/live/claude" "$TMP/live/cursor" "$TMP/live/codex"
cp "$REPO_ROOT/sync.sh" "$TMP/repo/sync.sh"; chmod +x "$TMP/repo/sync.sh"

# The fake source repo must be a real git repo: sync.sh now determines what to
# sync from `git ls-files`, not from the raw working directory.
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email "test@example.com"
git -C "$TMP/repo" config user.name "sync-test"

echo "rule content" > "$TMP/repo/claude/CLAUDE.md"
echo '{"a":1}' > "$TMP/repo/claude/settings.json"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" commit -q -m "fixture: initial tracked content"

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

# --- untracked source content must never sync and must never trip the JSON
# pre-flight, even when it is invalid JSON. This is the real-world scenario:
# `npm ci` drops a gitignored enforce/node_modules/ tree full of its own
# (non-strict) tsconfig.json files under claude/ in the working directory.
echo "{not valid json at all" > "$TMP/repo/claude/untracked-invalid.json"
mkdir -p "$TMP/repo/claude/untracked-dir/nested"
echo "{also not json" > "$TMP/repo/claude/untracked-dir/nested/tsconfig.json"
run_sync >"$TMP/untracked-run.log" 2>&1 || { echo "FAIL: sync refused because of untracked invalid JSON"; cat "$TMP/untracked-run.log"; exit 1; }
[ ! -e "$TMP/live/claude/untracked-invalid.json" ] || { echo "FAIL: untracked file leaked into destination"; exit 1; }
[ ! -e "$TMP/live/claude/untracked-dir" ] || { echo "FAIL: untracked directory leaked into destination"; exit 1; }
rm -rf "$TMP/repo/claude/untracked-invalid.json" "$TMP/repo/claude/untracked-dir"

# --- a tracked file removed from source (git rm) must disappear from the
# destination on the next sync: sync mirrors what's tracked, it never
# accumulates an ever-growing pile of previously-synced files.
echo "temporary" > "$TMP/repo/claude/removable.txt"
git -C "$TMP/repo" add claude/removable.txt
git -C "$TMP/repo" commit -q -m "fixture: add removable tracked file"
run_sync >/dev/null
[ -f "$TMP/live/claude/removable.txt" ] || { echo "FAIL: tracked file was not synced"; exit 1; }
git -C "$TMP/repo" rm -q claude/removable.txt
run_sync >/dev/null
[ ! -e "$TMP/live/claude/removable.txt" ] || { echo "FAIL: deleted tracked file was not removed from destination"; exit 1; }

rm -rf "$TMP"
echo "sync.test.sh PASS"
