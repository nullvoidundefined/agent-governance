#!/usr/bin/env bash
# session-metrics.test.sh: verifies hooks/session-metrics.sh (2026-09-17 skills
# audit, S-12): the R-602 metrics block from the session-start SHA stamp, or
# from --since; zeros with a note when nothing is recorded; rework and the
# velocity flag counted from real commits.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
METRICS="$CLAUDE_HARNESS_ROOT/hooks/session-metrics.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { printf '%s' "$OUT" | grep -qF "$1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
REPO="$SB/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"
START=$(git -C "$REPO" rev-parse HEAD)

# No stamp: zeros with a note, exit 0.
OUT=$(cd "$REPO" && bash "$METRICS" 2>&1); ST=$?
check "no stamp exits 0" test "$ST" -eq 0
check "no stamp reports zeros" reports "Commits this session: 0"
check "no stamp carries a note" reports "no session start SHA recorded"

# Stamp the start the way session-start.sh does (keyed by repo toplevel).
REPO_KEY=$(printf '%s' "$(git -C "$REPO" rev-parse --show-toplevel)" | shasum | awk '{print $1}')
printf '%s\n' "$START" > "$TMPDIR/claude-session-start-sha-$REPO_KEY"
OUT=$(cd "$REPO" && bash "$METRICS" 2>&1)
check "stamp with no commits reports zeros" reports "Commits this session: 0"

# Three commits, one file touched twice: 3 commits, 2 files, 1 rework.
printf 'b\n' > "$REPO/b.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "one"
printf 'c\n' > "$REPO/c.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "two"
printf 'bb\n' > "$REPO/b.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "three"
OUT=$(cd "$REPO" && bash "$METRICS" 2>&1)
check "commits counted" reports "Commits this session: 3"
check "files counted" reports "Files changed: 2"
check "revisited files counted" reports "Files revisited (touched by 2+ commits): 1"
check "flag normal" reports "Velocity flag: NORMAL"

# --since overrides the stamp.
MID=$(git -C "$REPO" rev-parse HEAD~1)
OUT=$(cd "$REPO" && bash "$METRICS" --since "$MID" 2>&1)
check "--since honoured" reports "Commits this session: 1"

# 41 commits flip the flag to HIGH with the action line.
for i in $(seq 1 38); do printf '%s\n' "$i" > "$REPO/n$i.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "n$i"; done
OUT=$(cd "$REPO" && bash "$METRICS" 2>&1)
check "flag high past 40" reports "Velocity flag: HIGH"
check "action line on high" reports "Action required"

# Outside a repository: zeros, note, exit 0.
OUT=$(cd "$SB" && bash "$METRICS" 2>&1); ST=$?
check "outside a repo exits 0" test "$ST" -eq 0
check "outside a repo notes it" reports "not inside a git repository"

[ "$fail" -eq 0 ] && echo "session-metrics.test.sh PASS"
exit "$fail"
