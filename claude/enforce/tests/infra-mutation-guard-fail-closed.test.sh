#!/usr/bin/env bash
# Verifies that infra-mutation-guard.sh fails closed. Run against a temp copy
# of claude/hooks, the wrapper must deny a Bash call (with a reason naming the
# judge, and exit 0) when, in turn: infra_judge.py is missing; the judge exits
# 3; the judge runs past the wrapper's timeout (the wrapper has no env knob, so
# the copy's JUDGE_TIMEOUT_SECONDS is lowered to 1); python3 is missing from
# PATH. It also checks that a malformed .enforce.json environments value (a
# string where a list belongs) denies a command that needs the lists, with a
# reason naming .enforce.json, and that with a working judge an ordinary
# command still gets no decision (so the denies above are not a hook that
# always denies).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)

REPO="$WORK/repo"; mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q

# fresh_hooks <name>: a copy of the hooks directory under $WORK/<name>.
fresh_hooks() {
  mkdir -p "$WORK/$1"
  cp -R "$CLAUDE_HARNESS_ROOT/hooks/." "$WORK/$1/"
}
[ -f "$CLAUDE_HARNESS_ROOT/hooks/infra-mutation-guard.sh" ] || { echo "FAIL: setup: infra-mutation-guard.sh missing"; exit 1; }
[ -f "$CLAUDE_HARNESS_ROOT/hooks/infra_judge.py" ] || { echo "FAIL: setup: infra_judge.py missing"; exit 1; }

# run_hook <hooks-dir> <path> <command> [cwd]: sets OUT and STATUS.
run_hook() {
  local payload
  payload=$(jq -n --arg c "$3" --arg d "${4:-$REPO}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  STATUS=0
  OUT=$(cd "${4:-$REPO}" && printf '%s' "$payload" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    PATH="$2" CLAUDE_FIRE_LOG=/dev/null bash "$1/infra-mutation-guard.sh" 2>/dev/null) || STATUS=$?
}

# expect_judge_deny <label> <hooks-dir> <path> <command>
expect_judge_deny() {
  run_hook "$2" "$3" "$4"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: $1: hook exited $STATUS (must always exit 0)"; exit 1; }
  local d reason
  d=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo "not-json")
  [ "$d" = deny ] || { echo "FAIL: $1: expected deny, got $d: $OUT"; exit 1; }
  reason=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
  printf '%s' "$reason" | grep -qi 'judge' || { echo "FAIL: $1: reason does not name the judge: $reason"; exit 1; }
}

# 0. Control: a working judge gives no decision for an ordinary command.
fresh_hooks control
run_hook "$WORK/control" "$PATH" 'ls -la'
[ "$STATUS" -eq 0 ] && [ -z "$OUT" ] || { echo "FAIL: control: expected no output for ls -la, got status $STATUS: $OUT"; exit 1; }

# 1. The judge file is missing.
fresh_hooks missing
rm -f "$WORK/missing/infra_judge.py"
for cmd in 'ls -la' 'terraform plan' 'aws s3 ls'; do
  expect_judge_deny "judge missing" "$WORK/missing" "$PATH" "$cmd"
done

# 2. The judge exits 3.
fresh_hooks exit3
printf 'import sys\nsys.exit(3)\n' > "$WORK/exit3/infra_judge.py"
for cmd in 'ls -la' 'aws s3 ls'; do
  expect_judge_deny "judge exits 3" "$WORK/exit3" "$PATH" "$cmd"
done

# 3. The judge sleeps past the timeout. The wrapper's timeout is a constant,
# so the copy lowers it to 1 second; the judge sleeps far longer.
fresh_hooks slow
printf 'import time\ntime.sleep(60)\n' > "$WORK/slow/infra_judge.py"
sed 's/^JUDGE_TIMEOUT_SECONDS=.*/JUDGE_TIMEOUT_SECONDS=1/' "$WORK/slow/infra-mutation-guard.sh" > "$WORK/slow/infra-mutation-guard.sh.new"
mv "$WORK/slow/infra-mutation-guard.sh.new" "$WORK/slow/infra-mutation-guard.sh"
grep -q '^JUDGE_TIMEOUT_SECONDS=1$' "$WORK/slow/infra-mutation-guard.sh" || { echo "FAIL: setup: could not lower the timeout in the copy"; exit 1; }
start=$(date +%s)
expect_judge_deny "judge times out" "$WORK/slow" "$PATH" 'ls -la'
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 30 ] || { echo "FAIL: judge timeout took ${elapsed}s, the watchdog did not fire"; exit 1; }

# 4. python3 is missing from PATH (every other program stays linked in).
fresh_hooks nopython
mkdir -p "$WORK/no-python"
OLD_IFS=$IFS
IFS=:
for dir in $PATH; do
  [ -d "$dir" ] || continue
  for program in "$dir"/*; do
    [ -f "$program" ] && [ -x "$program" ] || continue
    name=$(basename "$program")
    case "$name" in python*) continue ;; esac
    [ -e "$WORK/no-python/$name" ] || ln -s "$program" "$WORK/no-python/$name"
  done
done
IFS=$OLD_IFS
for needed in jq bash cat sleep; do
  [ -x "$WORK/no-python/$needed" ] || { echo "FAIL: setup: $needed missing from the no-python PATH"; exit 1; }
done
if PATH="$WORK/no-python" command -v python3 >/dev/null 2>&1; then
  echo "FAIL: setup: python3 still resolves on the no-python PATH"; exit 1
fi
for cmd in 'ls -la' 'aws s3 ls'; do
  expect_judge_deny "python3 missing" "$WORK/nopython" "$WORK/no-python" "$cmd"
done

# 5. A malformed .enforce.json environments value (string, not list) denies a
# command that needs the lists, and the reason names .enforce.json.
BAD="$WORK/badrepo"; mkdir -p "$BAD"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$BAD" init -q
printf '%s\n' '{"environments":{"production":"db.prod"}}' > "$BAD/.enforce.json"
run_hook "$CLAUDE_HARNESS_ROOT/hooks" "$PATH" 'kubectl --context x delete pod a' "$BAD"
[ "$STATUS" -eq 0 ] || { echo "FAIL: bad .enforce.json: hook exited $STATUS"; exit 1; }
d=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo "not-json")
[ "$d" = deny ] || { echo "FAIL: bad .enforce.json: expected deny, got $d: $OUT"; exit 1; }
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | grep -qF '.enforce.json' \
  || { echo "FAIL: bad .enforce.json: reason does not name .enforce.json: $OUT"; exit 1; }

echo "PASS: infra-mutation-guard-fail-closed"
