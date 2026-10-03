#!/usr/bin/env bash
# sync.test.sh: verifies sync.sh copies each folder into its target, never
# deletes anything it did not install (no rsync --delete, see sync.sh's header
# for why), removes a file it installed once the repository stops tracking it
# and only while its live content is unchanged (IAN-116), refuses on invalid JSON without a partial write, is idempotent, and
# syncs only git-tracked source content (never untracked/gitignored local
# state such as node_modules). Every target is a temp dir via the SYNC_*_HOME
# overrides, so this never touches a real ~/.claude, ~/.cursor, or ~/.codex.
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

# --- sync never deletes: pre-existing live-only content (runtime state, a
# stray file, anything) survives every sync unconditionally, there is no
# exclude list to keep current because there is nothing to protect against.
mkdir -p "$TMP/live/claude/sessions"; echo "keep me" > "$TMP/live/claude/sessions/marker.txt"
run_sync >/dev/null
[ -f "$TMP/live/claude/sessions/marker.txt" ] || { echo "FAIL: sync deleted live-only content it must never touch"; exit 1; }

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

# --- safe removal (IAN-116). sync.sh writes <target>/.sync-manifest, one
# "<sha256>  <path>" line per file it installed. On the next run it removes a
# live file only when the previous manifest lists it, the repository no longer
# tracks it, and its live content still hashes to the manifest's value; a file
# edited live is kept and reported, a file sync never installed is never
# touched, and a directory is removed only when that removal emptied it.
MANIFEST="$TMP/live/claude/.sync-manifest"
[ -f "$MANIFEST" ] || { echo "FAIL: sync did not write $MANIFEST"; exit 1; }
expected_line="$(shasum -a 256 "$TMP/repo/claude/CLAUDE.md" | awk '{print $1}')  CLAUDE.md"
grep -qxF "$expected_line" "$MANIFEST" || { echo "FAIL: manifest lacks '$expected_line'"; cat "$MANIFEST"; exit 1; }

mkdir -p "$TMP/repo/claude/nested/deep" "$TMP/repo/claude/shared"
echo "temporary" > "$TMP/repo/claude/removable.txt"
echo "temporary nested" > "$TMP/repo/claude/nested/deep/removable.txt"
echo "temporary shared" > "$TMP/repo/claude/shared/removable.txt"
echo "edited later" > "$TMP/repo/claude/edited.txt"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" commit -q -m "fixture: add removable tracked files"
run_sync >/dev/null
for f in removable.txt nested/deep/removable.txt shared/removable.txt edited.txt; do
  [ -f "$TMP/live/claude/$f" ] || { echo "FAIL: tracked file $f was not synced"; exit 1; }
done
# A live-only file beside a synced one: sync never installed it, so neither it
# nor the directory holding it may go when the synced neighbor is removed.
echo "mine" > "$TMP/live/claude/shared/own.txt"
echo "edited live" > "$TMP/live/claude/edited.txt"
git -C "$TMP/repo" rm -q claude/removable.txt claude/nested/deep/removable.txt claude/shared/removable.txt claude/edited.txt
git -C "$TMP/repo" commit -q -m "fixture: stop tracking the removable files"
run_sync >"$TMP/remove.out" 2>"$TMP/remove.err"
[ ! -e "$TMP/live/claude/removable.txt" ] || { echo "FAIL: a file sync installed and the repo stopped tracking was not removed"; exit 1; }
[ ! -e "$TMP/live/claude/nested" ] || { echo "FAIL: directories emptied by the removal were left behind"; exit 1; }
[ -f "$TMP/live/claude/shared/own.txt" ] || { echo "FAIL: a live file sync never installed was removed"; exit 1; }
[ ! -e "$TMP/live/claude/shared/removable.txt" ] || { echo "FAIL: a removed file beside a live-only file was not removed"; exit 1; }
[ -f "$TMP/live/claude/edited.txt" ] || { echo "FAIL: a file edited live since sync installed it was removed"; exit 1; }
grep -q "edited.txt" "$TMP/remove.err" || { echo "FAIL: a kept live-edited file was not reported"; cat "$TMP/remove.out" "$TMP/remove.err"; exit 1; }
grep -q "removable.txt" "$TMP/remove.out" || { echo "FAIL: a removal was not reported"; cat "$TMP/remove.out"; exit 1; }
[ -f "$TMP/live/claude/sessions/marker.txt" ] || { echo "FAIL: live-only runtime state was removed"; exit 1; }
if grep -q "removable.txt\|edited.txt" "$MANIFEST"; then echo "FAIL: the new manifest still lists files the repo no longer tracks"; exit 1; fi

# A rename that changes only letter case (local review on #69): on a
# case-insensitive volume (macOS by default) rsync --checksum leaves the old
# entry in place under the old spelling, and the old path resolves to the file
# the repository still tracks, so removing it would delete a tracked file. A
# candidate whose path matches a tracked path ignoring case is never removed.
echo "case rename" > "$TMP/repo/claude/CaseRename.txt"
git -C "$TMP/repo" add -A; git -C "$TMP/repo" commit -q -m "fixture: add case-rename file"
run_sync >/dev/null
git -C "$TMP/repo" mv claude/CaseRename.txt claude/caserename.txt
git -C "$TMP/repo" commit -q -m "fixture: rename by case only"
run_sync >/dev/null
[ -f "$TMP/live/claude/caserename.txt" ] || { echo "FAIL: a case-only rename removed the file the repository still tracks"; exit 1; }

# First run with no manifest (an install synced before manifests existed):
# nothing is removed, and the manifest is written for the next run.
echo "legacy" > "$TMP/repo/claude/legacy.txt"
git -C "$TMP/repo" add -A; git -C "$TMP/repo" commit -q -m "fixture: add legacy file"
run_sync >/dev/null
rm -f "$MANIFEST"
git -C "$TMP/repo" rm -q claude/legacy.txt; git -C "$TMP/repo" commit -q -m "fixture: stop tracking legacy file"
run_sync >/dev/null
[ -f "$TMP/live/claude/legacy.txt" ] || { echo "FAIL: a run with no previous manifest removed a file"; exit 1; }
[ -f "$MANIFEST" ] || { echo "FAIL: a run with no previous manifest did not write one"; exit 1; }

# A manifest line naming a path outside the target is never acted on.
outside="$TMP/outside.txt"; echo "outside" > "$outside"
printf '%s  ../outside.txt\n' "$(shasum -a 256 "$outside" | awk '{print $1}')" >> "$MANIFEST"
run_sync >/dev/null 2>&1
[ -f "$outside" ] || { echo "FAIL: a manifest entry escaping the target removed a file outside it"; exit 1; }

rm -rf "$TMP"
echo "sync.test.sh PASS"
