#!/usr/bin/env bash
# Coverage declaration for hook:destructive-ops-guard lands with its manifest
# row when slice B-1 closes (IAN-606), since the closure check needs the hook.
# Verifies that destructive-ops-guard.sh fails closed when its command parser
# (python3 running hooks/shell-command-segments.py) is unavailable or fails:
# every Bash call is denied with a reason naming the parser failure, whether
# it names a guarded program as a word, names none, or names one only inside
# a longer word (owner decision 2026-10-03, slice B-2). It also verifies that,
# with the parser working, ordinary non-destructive commands get no decision,
# and that empty, malformed, or non-Bash input gets no decision. The hook
# must exit 0 in every case, since an erroring PreToolUse hook is a non-decision.
#
# Two broken-parser setups are exercised: a stub python3 first on PATH that
# exits 1, and a PATH that carries no python3 at all but still has jq, bash,
# and the coreutils (every other program on the normal PATH is linked in).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/destructive-ops-guard.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# PATH with a python3 that exists but exits 1 (the macOS developer-tools stub
# shape, or a helper that crashes).
mkdir -p "$WORK/failing-python"
printf '#!/bin/sh\nexit 1\n' > "$WORK/failing-python/python3"
chmod +x "$WORK/failing-python/python3"
FAILING_PYTHON_PATH="$WORK/failing-python:$PATH"

# PATH with no python at all: every executable on the normal PATH is linked
# into one directory except python and python3 in any spelling.
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
NO_PYTHON_PATH="$WORK/no-python"
for needed in jq bash cat grep sed; do
  [ -x "$NO_PYTHON_PATH/$needed" ] || { echo "FAIL: setup: $needed missing from the no-python PATH"; exit 1; }
done
if PATH="$NO_PYTHON_PATH" command -v python3 >/dev/null 2>&1; then
  echo "FAIL: setup: python3 still resolves on the no-python PATH"; exit 1
fi

CWD="$(cd "$CLAUDE_HARNESS_ROOT/.." && pwd)"

# run_hook <path> <stdin>: runs the hook under the given PATH, sets OUT and
# STATUS. A non-zero exit is a FAIL on its own: the hook must always exit 0.
run_hook() {
  STATUS=0
  OUT=$(printf '%s' "$2" | env PATH="$1" "$HOOK" 2>/dev/null) || STATUS=$?
}

payload() {
  jq -n --arg c "$1" --arg d "$CWD" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}

# decision_of <path> <stdin> <label>: prints none, deny, ask, or the raw output
# when it is not a decision object.
decision_of() {
  run_hook "$1" "$2"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: hook exited $STATUS (must always exit 0) for: $3"; exit 1; }
  if [ -z "$OUT" ]; then
    DECISION=none
  else
    DECISION=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null) \
      || { echo "FAIL: hook printed output that is not JSON for: $3: $OUT"; exit 1; }
  fi
}

# expect <decision> <path-label> <path> <command>
expect() {
  decision_of "$3" "$(payload "$4")" "$4 ($2)"
  [ "$DECISION" = "$1" ] || { echo "FAIL: expected $1, got $DECISION ($2) for: $4"; exit 1; }
}

# expect_parser_deny <path-label> <path> <command>: deny, and the reason names
# the parser failure, and the event name is PreToolUse.
expect_parser_deny() {
  expect deny "$1" "$2" "$3"
  event=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""')
  [ "$event" = "PreToolUse" ] || { echo "FAIL: hookEventName was '$event', not PreToolUse ($1) for: $3"; exit 1; }
  reason=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
  printf '%s' "$reason" | grep -qi 'parser' \
    || { echo "FAIL: deny reason does not name the parser failure ($1) for: $3: $reason"; exit 1; }
}

# expect_raw_none <path-label> <path> <stdin> <label>
expect_raw_none() {
  decision_of "$2" "$3" "$4 ($1)"
  [ "$DECISION" = none ] && [ -z "$OUT" ] \
    || { echo "FAIL: expected no output ($1) for $4, got: $OUT"; exit 1; }
}

GUARDED_COMMANDS='rm -rf build
rm notes.txt
rmdir out
unlink stale.lock
trash old-dir
find . -name "*.o" -delete
ls | xargs echo
rsync -a src/ dst/
docker ps
docker rm -f web
podman ps
nerdctl images
docker-compose ps
kubectl get pods
helm list
terraform plan
pulumi preview
dd if=/dev/zero of=out.img bs=1 count=1
diskutil list
mkfs /dev/disk9
/bin/rm -rf build
sudo docker rm -f web
bash -c "docker rm -f web"
echo start; rm -rf build
cd /tmp && kubectl delete pod x'

UNGUARDED_COMMANDS='ls -la
echo hello
cat README.md
cat dockerfile.md
cat claude/hooks/dockerfile-reminder.sh
echo legit firmware
npm install helmet
cat ddos-notes.txt
git status'

for label in failing-python no-python; do
  if [ "$label" = failing-python ]; then path=$FAILING_PYTHON_PATH; else path=$NO_PYTHON_PATH; fi
  while IFS= read -r command_text; do
    [ -n "$command_text" ] || continue
    expect_parser_deny "$label" "$path" "$command_text"
  done <<< "$GUARDED_COMMANDS"
  while IFS= read -r command_text; do
    [ -n "$command_text" ] || continue
    expect_parser_deny "$label" "$path" "$command_text"
  done <<< "$UNGUARDED_COMMANDS"
  # A non-Bash tool stays silent even with the parser broken.
  expect_raw_none "$label" "$path" '{"tool_name":"Write","tool_input":{"file_path":"x","content":"rm -rf /"}}' "a Write call"
done

# With the parser working, ordinary commands get no decision, including ones
# that mention a guarded program only as data.
while IFS= read -r command_text; do
  [ -n "$command_text" ] || continue
  expect none working-parser "$PATH" "$command_text"
done <<'EOF'
ls -la
git status
echo rm is a word
cat notes-about-rm.txt
grep -rn "rm -rf" docs
npm test
python3 -c "print(1)"
cat dockerfile.md
EOF

# Empty, malformed, or non-Bash input: no decision, exit 0.
expect_raw_none working-parser "$PATH" '' "empty stdin"
expect_raw_none working-parser "$PATH" '{"tool_name": "Bash", ' "malformed JSON"
expect_raw_none working-parser "$PATH" 'not json at all' "non-JSON text"
expect_raw_none working-parser "$PATH" '{"tool_name":"Read","tool_input":{"command":"rm -rf /"}}' "a Read call"
expect_raw_none working-parser "$PATH" '{"tool_name":"Write","tool_input":{"file_path":"x","content":"docker rm -f web"}}' "a Write call"

echo "PASS: destructive-ops-guard-fail-closed"
