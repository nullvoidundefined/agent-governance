#!/usr/bin/env bash
# Coverage declaration for hook:destructive-ops-guard lands with its manifest
# row when slice B-1 closes (IAN-606), since the closure check needs the hook.
# Verifies slice B-2 of destructive-ops-guard.sh: while its command parser
# (python3 running hooks/shell-command-segments.py) is unusable, or jq is
# missing, EVERY Bash call is denied, not only calls that name a guarded
# program (owner decision 2026-10-03: word matching is bypassed by quoting,
# case, and eval while the parser is down).
#
# Unusable parser setups exercised:
#   no-python       a PATH with no python3 at all (jq, bash, coreutils present)
#   failing-python  a python3 first on PATH that exits 1
#   silent-python   a python3 first on PATH that exits 0 and prints nothing
#   slow-python     a python3 first on PATH that sleeps 30 s; the hook bounds
#                   the parser at 10 s, so a deny must arrive well before 30 s
#   missing-helper  a copy of the hook in a temp dir with no sibling
#                   shell-command-segments.py (the real python3 on PATH)
# In each, every command in DENIED_WHEN_DOWN gets deny with a reason naming
# the parser, while non-Bash and empty or malformed input gets no output.
#
# With no jq on PATH (bash, python3, and coreutils present), a Bash call must
# still produce a deny decision on stdout; the output is parsed with the real
# jq from outside the restricted PATH.
#
# With the parser working, ordinary commands still get no decision. The hook
# must exit 0 in every case; every run is bounded with timeout.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/destructive-ops-guard.sh"

JQ=$(command -v jq) || { echo "FAIL: setup: jq is required to run this fixture"; exit 1; }
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
[ -n "$TIMEOUT_BIN" ] || { echo "FAIL: setup: timeout (or gtimeout) is required to bound the hook"; exit 1; }
# Every hook run is killed after this many seconds; a kill is a FAIL.
RUN_BOUND=25
# The slow parser sleeps 30 s; the hook's bound is 10 s, so the deny must
# arrive within this many seconds.
SLOW_LIMIT=20

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

make_stub() {
  mkdir -p "$WORK/$1"
  printf '#!/bin/sh\n%s\n' "$2" > "$WORK/$1/python3"
  chmod +x "$WORK/$1/python3"
}
make_stub failing-python 'exit 1'
make_stub silent-python 'cat >/dev/null; exit 0'
make_stub slow-python 'exec sleep 30'
FAILING_PYTHON_PATH="$WORK/failing-python:$PATH"
SILENT_PYTHON_PATH="$WORK/silent-python:$PATH"
SLOW_PYTHON_PATH="$WORK/slow-python:$PATH"

# link_path_without <dir> <case-pattern>: links every executable on the normal
# PATH into <dir> except names matching the pattern.
link_path_without() {
  mkdir -p "$1"
  OLD_IFS=$IFS
  IFS=:
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for program in "$dir"/*; do
      [ -f "$program" ] && [ -x "$program" ] || continue
      name=$(basename "$program")
      # shellcheck disable=SC2254
      case "$name" in $2) continue ;; esac
      [ -e "$1/$name" ] || ln -s "$program" "$1/$name"
    done
  done
  IFS=$OLD_IFS
}

NO_PYTHON_PATH="$WORK/no-python"
link_path_without "$NO_PYTHON_PATH" 'python*'
for needed in jq bash cat grep sed; do
  [ -x "$NO_PYTHON_PATH/$needed" ] || { echo "FAIL: setup: $needed missing from the no-python PATH"; exit 1; }
done
if PATH="$NO_PYTHON_PATH" command -v python3 >/dev/null 2>&1; then
  echo "FAIL: setup: python3 still resolves on the no-python PATH"; exit 1
fi

NO_JQ_PATH="$WORK/no-jq"
link_path_without "$NO_JQ_PATH" 'jq*'
for needed in python3 bash cat grep sed; do
  [ -x "$NO_JQ_PATH/$needed" ] || { echo "FAIL: setup: $needed missing from the no-jq PATH"; exit 1; }
done
if PATH="$NO_JQ_PATH" command -v jq >/dev/null 2>&1; then
  echo "FAIL: setup: jq still resolves on the no-jq PATH"; exit 1
fi

# A copy of the hook with no sibling parser helper; the repo is not touched.
mkdir -p "$WORK/lonely-hook"
cp "$HOOK" "$WORK/lonely-hook/destructive-ops-guard.sh"
chmod +x "$WORK/lonely-hook/destructive-ops-guard.sh"
LONELY_HOOK="$WORK/lonely-hook/destructive-ops-guard.sh"
[ ! -e "$WORK/lonely-hook/shell-command-segments.py" ] || { echo "FAIL: setup: helper present beside the hook copy"; exit 1; }

CWD="$(cd "$CLAUDE_HARNESS_ROOT/.." && pwd)"

payload() {
  "$JQ" -n --arg c "$1" --arg d "$CWD" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}

# run_hook <hook> <path> <stdin>: runs the hook under the given PATH, bounded,
# sets OUT and STATUS.
run_hook() {
  STATUS=0
  OUT=$(printf '%s' "$3" | "$TIMEOUT_BIN" "$RUN_BOUND" env PATH="$2" "$1" 2>/dev/null) || STATUS=$?
}

# check_output <label>: from OUT and STATUS, sets DECISION (none, deny, ask).
check_output() {
  [ "$STATUS" -ne 124 ] || { echo "FAIL: hook did not finish within ${RUN_BOUND}s for: $1"; exit 1; }
  [ "$STATUS" -eq 0 ] || { echo "FAIL: hook exited $STATUS (must always exit 0) for: $1"; exit 1; }
  if [ -z "$OUT" ]; then
    DECISION=none
  else
    DECISION=$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null) \
      || { echo "FAIL: hook printed output that is not JSON for: $1: $OUT"; exit 1; }
  fi
}

# check_deny <label> <want-parser-reason yes|no>: OUT is a PreToolUse deny.
check_deny() {
  check_output "$1"
  [ "$DECISION" = deny ] || { echo "FAIL: expected deny, got $DECISION for: $1"; exit 1; }
  event=$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.hookEventName // ""')
  [ "$event" = "PreToolUse" ] || { echo "FAIL: hookEventName was '$event', not PreToolUse for: $1"; exit 1; }
  if [ "$2" = yes ]; then
    reason=$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason // ""')
    printf '%s' "$reason" | grep -qi 'parser' \
      || { echo "FAIL: deny reason does not name the parser for: $1: $reason"; exit 1; }
  fi
}

# expect_parser_deny <label> <hook> <path> <command>
expect_parser_deny() {
  run_hook "$2" "$3" "$(payload "$4")"
  check_deny "$4 ($1)" yes
}

# expect_none <label> <hook> <path> <command>
expect_none() {
  run_hook "$2" "$3" "$(payload "$4")"
  check_output "$4 ($1)"
  [ "$DECISION" = none ] || { echo "FAIL: expected no decision, got $DECISION ($1) for: $4"; exit 1; }
}

# expect_raw_none <label> <hook> <path> <stdin> <what>
expect_raw_none() {
  run_hook "$2" "$3" "$4"
  check_output "$5 ($1)"
  [ -z "$OUT" ] || { echo "FAIL: expected no output ($1) for $5, got: $OUT"; exit 1; }
}

# Commands denied while the parser is down: harmless ones, and destructive
# ones spelled to defeat word matching.
DENIED_WHEN_DOWN=$(cat <<'EOF'
ls -la
echo hello
git status
r''m -rf ~
"r"m -rf /
RM -rf ~
eval "$(printf '\162m -rf ~')"
X=r; ${X}m -rf ~
perl -e 'use File::Path; rmtree(q(/Users))'
node -e 'require("fs").rmSync("/x",{recursive:true})'
: > ~/.zshrc
shred -u ~/.ssh/id_ed25519
EOF
)

quiet_inputs_stay_silent() {
  expect_raw_none "$1" "$2" "$3" '' "empty stdin"
  expect_raw_none "$1" "$2" "$3" '{"tool_name": "Bash", ' "malformed JSON"
  expect_raw_none "$1" "$2" "$3" 'not json at all' "non-JSON text"
  expect_raw_none "$1" "$2" "$3" '{"tool_name":"Read","tool_input":{"file_path":"x","command":"rm -rf /"}}' "a Read call"
  expect_raw_none "$1" "$2" "$3" '{"tool_name":"Write","tool_input":{"file_path":"x","content":"rm -rf /"}}' "a Write call"
}

# Sequential setups.
for label in no-python failing-python silent-python missing-helper; do
  hook=$HOOK
  case "$label" in
    no-python) path=$NO_PYTHON_PATH ;;
    failing-python) path=$FAILING_PYTHON_PATH ;;
    silent-python) path=$SILENT_PYTHON_PATH ;;
    missing-helper) path=$PATH; hook=$LONELY_HOOK ;;
  esac
  while IFS= read -r command_text; do
    [ -n "$command_text" ] || continue
    expect_parser_deny "$label" "$hook" "$path" "$command_text"
  done <<< "$DENIED_WHEN_DOWN"
  quiet_inputs_stay_silent "$label" "$hook" "$path"
done

# slow-python: run every command in parallel so the fixture stays short, then
# require each to be denied and the whole batch to finish within SLOW_LIMIT.
mkdir -p "$WORK/slow-runs"
started=$(date +%s)
i=0
while IFS= read -r command_text; do
  [ -n "$command_text" ] || continue
  i=$((i + 1))
  printf '%s' "$command_text" > "$WORK/slow-runs/$i.cmd"
  (
    st=0
    payload "$command_text" | "$TIMEOUT_BIN" "$RUN_BOUND" env PATH="$SLOW_PYTHON_PATH" "$HOOK" \
      > "$WORK/slow-runs/$i.out" 2>/dev/null || st=$?
    printf '%s' "$st" > "$WORK/slow-runs/$i.status"
  ) &
done <<< "$DENIED_WHEN_DOWN"
wait
elapsed=$(( $(date +%s) - started ))
j=1
while [ "$j" -le "$i" ]; do
  OUT=$(cat "$WORK/slow-runs/$j.out")
  STATUS=$(cat "$WORK/slow-runs/$j.status")
  check_deny "$(cat "$WORK/slow-runs/$j.cmd") (slow-python)" yes
  j=$((j + 1))
done
[ "$elapsed" -le "$SLOW_LIMIT" ] \
  || { echo "FAIL: slow-python: denies took ${elapsed}s, more than ${SLOW_LIMIT}s (parser bound is 10 s)"; exit 1; }
quiet_inputs_stay_silent slow-python "$HOOK" "$SLOW_PYTHON_PATH"

# no-jq: the hook cannot use jq to emit, yet must still print a deny.
for command_text in 'rm -rf ~' 'ls -la' 'git status'; do
  run_hook "$HOOK" "$NO_JQ_PATH" "$(payload "$command_text")"
  check_deny "$command_text (no-jq)" no
done

# Working parser: ordinary commands get no decision.
while IFS= read -r command_text; do
  [ -n "$command_text" ] || continue
  expect_none working-parser "$HOOK" "$PATH" "$command_text"
done <<'EOF'
ls -la
git status
echo rm is a word
EOF
quiet_inputs_stay_silent working-parser "$HOOK" "$PATH"

echo "PASS: destructive-ops-guard-parser-down"
