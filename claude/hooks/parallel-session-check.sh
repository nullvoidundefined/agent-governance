#!/usr/bin/env bash
# parallel-session-check.sh: R-501. Two sessions editing one working tree
# interleave writes that neither one sees, and the loser finds out at the next
# read. The rule says check before the first edit; nothing checked, because a
# session cannot see its siblings.
#
# Each session registers its own PID under a key derived from the working tree
# it started in. A registration survives only while its process does, so a
# crashed or closed session prunes itself on the next check and no cleanup hook
# is required. Warns, never blocks: a second session is sometimes deliberate.
set -euo pipefail
INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)
[ -n "$CWD" ] || CWD="$PWD"
TREE=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$CWD")

LOCK_DIR="${CLAUDE_SESSION_LOCK_DIR:-$HOME/.claude/.session-locks}"
mkdir -p "$LOCK_DIR" 2>/dev/null || exit 0
KEY=$(printf '%s' "$TREE" | shasum 2>/dev/null | awk '{print $1}')
[ -n "$KEY" ] || exit 0
REGISTRY="$LOCK_DIR/$KEY"

# The hook runs a few processes below the session itself, so walk up to the
# first ancestor that is the CLI and register that, not this shell: a shell PID
# is dead by the next check and would make every session look solitary.
session_pid() {
  local pid="$PPID" name parent
  for _ in 1 2 3 4 5 6; do
    { [ -z "$pid" ] || [ "$pid" -le 1 ]; } && break
    name=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    case "$name" in *claude* | *node*) printf '%s' "$pid"; return 0 ;; esac
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] && break
    pid="$parent"
  done
  printf '%s' "$PPID"
}

MY_PID=$(session_pid)
LIVE=""
OTHERS=0
if [ -f "$REGISTRY" ]; then
  while IFS= read -r recorded_pid || [ -n "$recorded_pid" ]; do
    [ -z "$recorded_pid" ] && continue
    [ "$recorded_pid" = "$MY_PID" ] && continue
    kill -0 "$recorded_pid" 2>/dev/null || continue
    LIVE="$LIVE$recorded_pid
"
    OTHERS=$((OTHERS + 1))
  done < "$REGISTRY"
fi
printf '%s%s\n' "$LIVE" "$MY_PID" >"$REGISTRY"
[ "$OTHERS" -eq 0 ] && exit 0

source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-501" "parallel-session-check" "warn"

jq -n --arg tree "$TREE" --arg count "$OTHERS" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("R-501: " + $count + " other live Claude session(s) are already working in " + $tree + ". Two sessions on one working tree overwrite each other silently. Move this session to a git worktree before the first edit (git worktree add ../<name> -b <branch>), or confirm with the user that the parallel work is deliberate and scoped to different files.")}}'
exit 0
