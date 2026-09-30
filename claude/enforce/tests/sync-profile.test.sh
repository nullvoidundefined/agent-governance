#!/usr/bin/env bash
# Shard: slow
# Watches: sync.sh translate/* enforce/harness-profiles.json
# Verifies sync.sh --profile (IAN-518): `./sync.sh --profile lean` installs the
# lean tree into all three targets and records the profile in
# <claude target>/.harness-profile; a plain `./sync.sh` (what the harness-sync
# SessionStart hook runs) keeps the recorded profile instead of silently
# reverting it; `./sync.sh --profile full` (or HARNESS_PROFILE=full) restores
# every file and clears the record. Removals still go only through the
# .sync-manifest allowlist: a live-only file survives, and a file edited live
# is kept and reported. Every target is a temp dir through the SYNC_*_HOME
# overrides and npm is replaced by `true`, so this never touches a real home.
set -uo pipefail
REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
lacks() { ! grep -q -- "$1" "$2"; }
same_file() { cmp -s "$1" "$2"; }

REPO="$TMP/repo"
LIVE="$TMP/live"
mkdir -p "$REPO" "$LIVE/claude" "$LIVE/cursor" "$LIVE/codex"
git -C "$REPO_TOP" ls-files -- claude translate cursor codex sync.sh >"$TMP/tracked.txt"
rsync -a --files-from="$TMP/tracked.txt" "$REPO_TOP/" "$REPO/"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "sync-profile-test"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "fixture: tracked harness"

# run_sync [args...]: sync.sh into the sandbox targets; HARNESS_PROFILE passes
# through from the caller's environment only when the caller sets it.
run_sync() {
  SYNC_CLAUDE_HOME="$LIVE/claude" SYNC_CURSOR_HOME="$LIVE/cursor" SYNC_CODEX_HOME="$LIVE/codex" SYNC_NPM=true \
    "$REPO/sync.sh" "$@"
}

# --- Baseline: the default sync installs everything and records no profile.
unset HARNESS_PROFILE
run_sync >"$TMP/full.log" 2>&1
check "baseline sync exits 0" test $? -eq 0
cp "$LIVE/claude/.sync-manifest" "$TMP/full-claude-manifest"
cp "$LIVE/cursor/.sync-manifest" "$TMP/full-cursor-manifest"
cp "$LIVE/codex/.sync-manifest" "$TMP/full-codex-manifest"
check "baseline installs the gof SKILL.md" test -f "$LIVE/claude/skills/gof/SKILL.md"
check "baseline records no profile" test ! -e "$LIVE/claude/.harness-profile"

# Live-only state and a live edit to a file lean hides.
mkdir -p "$LIVE/claude/sessions"; echo "keep me" >"$LIVE/claude/sessions/marker.txt"
echo "local note" >>"$LIVE/claude/PROTOCOL.md"

# --- Lean.
run_sync --profile lean >"$TMP/lean.log" 2>"$TMP/lean.err"
check "--profile lean exits 0" test $? -eq 0
check "lean records the profile" grep -qx 'lean' "$LIVE/claude/.harness-profile"
check "lean CLAUDE.md drops R-001" lacks '^R-001:' "$LIVE/claude/CLAUDE.md"
check "lean CLAUDE.md keeps R-101" grep -q '^R-101:' "$LIVE/claude/CLAUDE.md"
check "lean removes the gof SKILL.md" test ! -e "$LIVE/claude/skills/gof/SKILL.md"
check "lean removes the emptied gof folder" test ! -e "$LIVE/claude/skills/gof"
check "lean removes the python rule symlink" test ! -L "$LIVE/claude/rules/python.md"
check "lean removes an audit agent" test ! -e "$LIVE/claude/agents/audit-ux.md"
check "lean keeps task-tier.sh executable" test -x "$LIVE/claude/skills/task-start/scripts/task-tier.sh"
check "lean keeps build-lane.sh" test -f "$LIVE/claude/skills/build-fast/scripts/build-lane.sh"
check "lean keeps rulebook/reference.md" test -f "$LIVE/claude/rulebook/reference.md"
check "lean settings.json drops session-start" lacks 'hooks/session-start.sh' "$LIVE/claude/settings.json"
check "lean settings.json keeps harness-sync" grep -q 'hooks/harness-sync.sh' "$LIVE/claude/settings.json"
check "lean settings.json keeps secret-scan" grep -q 'hooks/secret-scan.sh' "$LIVE/claude/settings.json"
check "lean keeps the hook files themselves" test -f "$LIVE/claude/hooks/session-start.sh"
check "lean cursor target drops the gof SKILL.md" test ! -e "$LIVE/cursor/skills/gof/SKILL.md"
check "lean cursor target drops the session-types rule" test ! -e "$LIVE/cursor/rules/001-session-types.mdc"
check "lean codex target drops R-001" lacks '^R-001:' "$LIVE/codex/AGENTS.md"
check "lean codex target keeps task-tier.sh" test -f "$LIVE/codex/skills/task-start/scripts/task-tier.sh"
check "lean never touches live-only state" test -f "$LIVE/claude/sessions/marker.txt"
check "lean keeps a hidden file that was edited live" test -f "$LIVE/claude/PROTOCOL.md"
check "lean reports the kept live edit" grep -q 'KEPT: .*PROTOCOL.md' "$TMP/lean.err"
check "lean leaves the source checkout untouched" test -f "$REPO/claude/skills/gof/SKILL.md"
check "lean leaves the source CLAUDE.md untouched" grep -q '^R-001:' "$REPO/claude/CLAUDE.md"
check "lean leaves the source cursor port untouched" test -f "$REPO/cursor/skills/gof/SKILL.md"

# --- A plain sync keeps the recorded profile (harness-sync runs exactly this).
run_sync >"$TMP/plain.log" 2>&1
check "plain sync after lean exits 0" test $? -eq 0
check "plain sync keeps the lean CLAUDE.md" lacks '^R-001:' "$LIVE/claude/CLAUDE.md"
check "plain sync keeps the gof SKILL.md hidden" test ! -e "$LIVE/claude/skills/gof/SKILL.md"
check "plain sync keeps the record" grep -qx 'lean' "$LIVE/claude/.harness-profile"
check "plain sync names the recorded profile" grep -q 'lean' "$TMP/plain.log"

# --- An unknown profile refuses before any target is written.
cp "$LIVE/claude/CLAUDE.md" "$TMP/claude-before-refusal.md"
run_sync --profile no-such-profile >"$TMP/bad.log" 2>"$TMP/bad.err"
check "an unknown profile exits nonzero" test $? -ne 0
check "an unknown profile says REFUSED" grep -q 'REFUSED' "$TMP/bad.err"
check "an unknown profile leaves CLAUDE.md untouched" same_file "$TMP/claude-before-refusal.md" "$LIVE/claude/CLAUDE.md"
check "an unknown profile leaves the record untouched" grep -qx 'lean' "$LIVE/claude/.harness-profile"
run_sync --profile >/dev/null 2>&1
check "a bare --profile exits nonzero" test $? -ne 0

# --- --profile full restores everything and clears the record.
run_sync --profile full >"$TMP/restore.log" 2>&1
check "--profile full exits 0" test $? -eq 0
check "full restores CLAUDE.md byte for byte" same_file "$REPO/claude/CLAUDE.md" "$LIVE/claude/CLAUDE.md"
check "full restores settings.json byte for byte" same_file "$REPO/claude/settings.json" "$LIVE/claude/settings.json"
check "full restores the gof SKILL.md" test -f "$LIVE/claude/skills/gof/SKILL.md"
check "full restores the python rule symlink" test -L "$LIVE/claude/rules/python.md"
check "full restores the edited PROTOCOL.md" same_file "$REPO/claude/PROTOCOL.md" "$LIVE/claude/PROTOCOL.md"
check "full clears the record" test ! -e "$LIVE/claude/.harness-profile"
check "full claude manifest equals the baseline" same_file "$TMP/full-claude-manifest" "$LIVE/claude/.sync-manifest"
check "full cursor manifest equals the baseline" same_file "$TMP/full-cursor-manifest" "$LIVE/cursor/.sync-manifest"
check "full codex manifest equals the baseline" same_file "$TMP/full-codex-manifest" "$LIVE/codex/.sync-manifest"

# --- HARNESS_PROFILE selects a profile the same way, and full undoes it.
HARNESS_PROFILE=lean run_sync >/dev/null 2>&1
check "HARNESS_PROFILE=lean installs lean" test ! -e "$LIVE/claude/skills/gof/SKILL.md"
HARNESS_PROFILE=full run_sync >/dev/null 2>&1
check "HARNESS_PROFILE=full restores" test -f "$LIVE/claude/skills/gof/SKILL.md"
check "HARNESS_PROFILE=full clears the record" test ! -e "$LIVE/claude/.harness-profile"
run_sync >/dev/null 2>&1
check "a plain sync with no record stays full" test -f "$LIVE/claude/skills/gof/SKILL.md"

exit "$fail"
