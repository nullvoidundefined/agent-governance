#!/usr/bin/env bash
# Covers: enforce/qwen-implementer-dispatch.sh
# Shard: slow
# qwen-implementer-dispatch.test.sh: verifies the local Qwen GREEN-attempt
# runner (slice 05 PR 2,
# docs/slices/slice-05-tiered-agents-and-local-qwen-implementer.md).
#
#   qwen-implementer-dispatch.sh --repo <root> --red <sha> --prompt <file>
#                                --log <file> --test-cmd <command>
#
# Line 1 of stdout is the status, line 2 the reason.
#   green        exit 0  the test command passed and no protected path changed
#   failed       exit 1  tests-failed (last 60 lines of test output from line 3),
#                        touched-protected-path (line 2 names the path),
#                        timeout, turn-limit, process-error
#   unavailable  exit 3  no-secondary-configured, server-unreachable, model-missing
#   usage errors exit 2
# Protected paths are the tests, specs and lock patterns of
# enforce/role-policy.json, matched against every path that differs from the
# RED sha, tracked or untracked.
#
# Method: stub `claude` and `curl` executables sit first on PATH, and every
# case works in its own throwaway git repository whose RED commit holds a
# failing test (tests/value_check.sh) and a production file (src/value.sh).
# No case contacts a real server or model. The stubs read their behaviour
# from files under $WORK (not from the environment, which the script is
# free to rewrite) and record what they saw to files under $WORK.
# The turn-limit reason has no case: the exit code and message Claude Code
# uses when --max-turns is reached are not known yet (spike result).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/qwen-implementer-dispatch.sh"

# A hook or caller may export GIT_DIR and friends; they must not leak into the
# fixture repositories (global memory: lesson_strip_git_env_in_hook_tests).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX

failCase() {
  echo "FAIL: $1"
  exit 1
}

[ -f "$SCRIPT" ] || failCase "the dispatch script does not exist at $SCRIPT (not implemented yet)"

WORK=$(cd "$(mktemp -d)" && pwd -P)
# Kills any stub child a broken timeout left behind, then removes the temp dir.
cleanupWork() {
  local pid
  if [ -f "$WORK/stub-pids" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
    done <"$WORK/stub-pids"
  fi
  rm -rf "$WORK"
}
trap cleanupWork EXIT

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"
unset QWEN_DISPATCH_TIMEOUT_SECONDS QWEN_DISPATCH_MAX_TURNS QWEN_DISPATCH_IDLE_SECONDS AGENT_TIER_ASSIGNMENTS_FILE
# The caller's own Anthropic settings: the script must not change them, and
# the stub must not receive the caller's endpoint.
export ANTHROPIC_BASE_URL="https://caller.example.invalid"
export ANTHROPIC_AUTH_TOKEN="caller-token-placeholder"
unset ANTHROPIC_API_KEY

# --- Stub claude. ---
# Mode comes from $WORK/claude-mode. Every start appends one line to
# $WORK/claude-starts and overwrites $WORK/claude-args (one argument per
# line, then a line "--END--") and $WORK/claude-env.
cat >"$STUBS/claude" <<EOF
#!/usr/bin/env bash
W="$WORK"
EOF
cat >>"$STUBS/claude" <<'EOF'
mode=$(cat "$W/claude-mode" 2>/dev/null || echo fix)
echo "start $$" >>"$W/claude-starts"
echo "$$" >>"$W/stub-pids"
: >"$W/claude-args"
for a in "$@"; do printf '%s\n' "$a" >>"$W/claude-args"; done
echo "--END--" >>"$W/claude-args"
stdin_got=""
if IFS= read -r -t 1 stdin_got 2>/dev/null; then :; fi
{
  echo "BASE_URL=${ANTHROPIC_BASE_URL-<unset>}"
  echo "AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-<unset>}"
  echo "API_KEY_SET=${ANTHROPIC_API_KEY+set}"
  echo "API_KEY=${ANTHROPIC_API_KEY-<unset>}"
  echo "PWD=$(pwd -P)"
  echo "STDIN=$stdin_got"
} >"$W/claude-env"
# The silent-* modes write nothing at all to stdout or stderr.
case "$mode" in
  silent-*) ;;
  *)
    echo "STUB-CLAUDE-STDOUT-$mode"
    echo "STUB-CLAUDE-STDERR-$mode" >&2
    ;;
esac
fixValue() { printf '#!/usr/bin/env bash\necho 2\n' >src/value.sh; }
case "$mode" in
  fix)
    fixValue
    printf 'helper\n' >src/new_module.sh
    ;;
  stream-fix)
    # stream-json lines like the real run: per-token system noise, a message,
    # a tool call, a 12-line tool result, then the final result.
    printf '%s\n' '{"type":"system","subtype":"token","n":1}' \
      '{"type":"assistant","message":{"content":[{"type":"text","text":"HELLO-FROM-QWEN"},{"type":"tool_use","name":"Bash","input":{"command":"ls src"}}]}}' \
      "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"$(seq -s '\\n' 1 12)\"}]}}" \
      '{"type":"result","result":"FINAL-WORDS"}'
    fixValue
    ;;
  wrong)
    printf '#!/usr/bin/env bash\necho 3\n' >src/value.sh
    ;;
  edit-test)
    fixValue
    printf '# reworded by the implementer\n' >>tests/value_check.sh
    ;;
  untracked-test-tree)
    fixValue
    printf 'echo extra\n' >tests/new_helper.sh
    ;;
  untracked-test-suffix)
    fixValue
    printf 'test("x", () => {});\n' >src/value.test.js
    ;;
  edit-spec)
    fixValue
    printf 'Reworded by the implementer.\n' >>docs/specs/value.md
    ;;
  write-lock)
    fixValue
    mkdir -p .claude
    printf '{}\n' >.claude/tdd-lock.json
    ;;
  commit-test)
    fixValue
    printf '# reworded by the implementer\n' >>tests/value_check.sh
    git add -A >/dev/null 2>&1
    git -c core.hooksPath=/dev/null -c user.email=s@s -c user.name=s commit -qm "stub commit" >/dev/null 2>&1
    ;;
  slow)
    sleep 30 &
    echo "$!" >"$W/slow-child-pid"
    echo "$!" >>"$W/stub-pids"
    echo "$$" >"$W/slow-stub-pid"
    wait
    ;;
  crash)
    exit 3
    ;;
  silent-hang)
    # No output at all, then a 30 s sleeping child: a hang before the first output.
    sleep 30 &
    echo "$!" >"$W/slow-child-pid"
    echo "$!" >>"$W/stub-pids"
    echo "$$" >"$W/slow-stub-pid"
    wait
    ;;
  silent-then-fix)
    # Silent for $W/claude-sleep seconds, then a passing fix.
    sleep "$(cat "$W/claude-sleep")"
    fixValue
    ;;
  trickle-fix)
    # One line on stdout every second for about 6 s, then a passing fix.
    i=1
    while [ "$i" -le 6 ]; do
      echo "STUB-CLAUDE-TRICKLE-$i"
      sleep 1
      i=$((i + 1))
    done
    fixValue
    ;;
esac
exit 0
EOF
chmod +x "$STUBS/claude"

# --- Stub curl. ---
# Mode comes from $WORK/curl-mode: up (lists the names in $WORK/curl-models),
# down (connection refused, exit 7). Honors -o/--output and -w/--write-out
# with %{http_code}. Records every URL argument to $WORK/curl-urls.
cat >"$STUBS/curl" <<EOF
#!/usr/bin/env bash
W="$WORK"
EOF
cat >>"$STUBS/curl" <<'EOF'
mode=$(cat "$W/curl-mode" 2>/dev/null || echo up)
out=""
wfmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o | --output) out="$2"; shift ;;
    --output=*) out="${1#--output=}" ;;
    -w | --write-out) wfmt="$2"; shift ;;
    --write-out=*) wfmt="${1#--write-out=}" ;;
    http://* | https://*) echo "$1" >>"$W/curl-urls" ;;
  esac
  shift
done
if [ "$mode" = down ]; then
  echo "curl: (7) Failed to connect: Connection refused" >&2
  [ -n "$wfmt" ] && printf '%s' "${wfmt//%\{http_code\}/000}"
  exit 7
fi
body='{"models":['
first=1
while read -r name; do
  [ -n "$name" ] || continue
  [ "$first" = 1 ] || body="$body,"
  body="$body{\"name\":\"$name\",\"model\":\"$name\",\"size\":1}"
  first=0
done <"$W/curl-models"
body="$body]}"
if [ -n "$out" ]; then printf '%s\n' "$body" >"$out"; else printf '%s\n' "$body"; fi
[ -n "$wfmt" ] && printf '%s' "${wfmt//%\{http_code\}/200}"
exit 0
EOF
chmod +x "$STUBS/curl"

# --- Fixture helpers. ---

# newCase <name>: resets stub state and builds a fresh RED repository at
# $REPO with RED=$RED (its HEAD), a prompt file, a log path, and the default
# machine file and server state. The RED commit holds:
#   src/value.sh          production; prints 1, the test wants 2
#   tests/value_check.sh  the failing test; prints 70 numbered lines first
#   docs/specs/value.md   a spec
CASE_DIR=""
newCase() {
  CASE_DIR="$WORK/$1"
  mkdir -p "$CASE_DIR"
  rm -f "$WORK/claude-starts" "$WORK/claude-args" "$WORK/claude-env" "$WORK/curl-urls" \
    "$WORK/slow-child-pid" "$WORK/slow-stub-pid"
  echo fix >"$WORK/claude-mode"
  echo up >"$WORK/curl-mode"
  printf 'qwen-coder-local:latest\nother-model:latest\n' >"$WORK/curl-models"
  REPO="$CASE_DIR/repo"
  mkdir -p "$REPO/src" "$REPO/tests" "$REPO/docs/specs"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  git -C "$REPO" config core.hooksPath /dev/null
  printf '#!/usr/bin/env bash\necho 1\n' >"$REPO/src/value.sh"
  cat >"$REPO/tests/value_check.sh" <<'TEST'
#!/usr/bin/env bash
i=1
while [ "$i" -le 70 ]; do printf 'check-line-%02d\n' "$i"; i=$((i + 1)); done
got=$(bash src/value.sh)
if [ "$got" = "2" ]; then echo "VALUE-CHECK-PASSED"; exit 0; fi
echo "VALUE-CHECK-FAILED: want 2 got $got"
exit 1
TEST
  printf '# Value\n\nThe value is 2.\n' >"$REPO/docs/specs/value.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "test: RED value check"
  RED=$(git -C "$REPO" rev-parse HEAD)
  REPO=$(cd "$REPO" && pwd -P)
  PROMPT="$CASE_DIR/prompt.txt"
  printf 'Make tests/value_check.sh pass. Do not commit.\n' >"$PROMPT"
  LOG="$CASE_DIR/run.log"
  TEST_CMD="bash tests/value_check.sh"
  writeMachineFile '{"primary": {"agent": "claude"}, "secondary": {"agent": "qwen", "model": "qwen-coder-local", "endpoint": "http://127.0.0.1:11434"}}'
}

# writeMachineFile <json>: writes the case's machine file and points the
# script at it.
writeMachineFile() {
  printf '%s\n' "$1" >"$CASE_DIR/machine.json"
  jq -e . "$CASE_DIR/machine.json" >/dev/null || failCase "setup: machine file JSON is malformed: $1"
  export AGENT_TIER_ASSIGNMENTS_FILE="$CASE_DIR/machine.json"
}

# dispatch <args...>: runs the script with stdin carrying a line the stub
# must never see; sets RC, OUT, ERR, STATUS (line 1), REASON (line 2), TAIL
# (line 3 on).
dispatch() {
  RC=0
  OUT=$(printf 'STDIN-LEAK\n' | bash "$SCRIPT" "$@" 2>"$WORK/err") || RC=$?
  ERR=$(cat "$WORK/err")
  STATUS=$(printf '%s\n' "$OUT" | sed -n 1p)
  REASON=$(printf '%s\n' "$OUT" | sed -n 2p)
  TAIL=$(printf '%s\n' "$OUT" | sed -n '3,$p')
}

# dispatchCase: dispatch with the case's full, valid argument set.
dispatchCase() {
  dispatch --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
}

# expectResult <what> <rc> <status> <reason-prefix>
expectResult() {
  [ "$RC" -eq "$2" ] || failCase "$1: want exit $2, got $RC (stdout: '$OUT', stderr: '$ERR')"
  [ "$STATUS" = "$3" ] || failCase "$1: line 1 must be '$3' (got '$STATUS'; stdout: '$OUT', stderr: '$ERR')"
  case "$REASON" in
    "$4"*) ;;
    *) failCase "$1: line 2 must start with '$4' (got '$REASON')" ;;
  esac
}

claudeStarts() {
  if [ -f "$WORK/claude-starts" ]; then wc -l <"$WORK/claude-starts" | tr -d ' '; else echo 0; fi
}

expectClaudeNeverStarted() {
  [ "$(claudeStarts)" = "0" ] || failCase "$1: claude must never start (it started $(claudeStarts) time(s))"
}

# expectLogHasRun <what> <mode>: the log holds the stub's stdout and stderr.
expectLogHasRun() {
  [ -f "$LOG" ] || failCase "$1: the run log must exist at --log $LOG"
  grep -q "STUB-CLAUDE-STDOUT-$2" "$LOG" || failCase "$1: the log must hold claude's stdout (log: $(head -c 2000 "$LOG"))"
  grep -q "STUB-CLAUDE-STDERR-$2" "$LOG" || failCase "$1: the log must hold claude's stderr (log: $(head -c 2000 "$LOG"))"
}

# expectReasonNames <what> <path>
expectReasonNames() {
  printf '%s\n' "$REASON" | grep -qF -- "$2" || failCase "$1: line 2 must name $2 (got '$REASON')"
}

envValue() { sed -n "s/^$1=//p" "$WORK/claude-env"; }

# argFollowing <flag>: prints the argument after <flag> in the recorded args.
argFollowing() { awk -v f="$1" 'p { print; exit } $0 == f { p = 1 }' "$WORK/claude-args"; }

# processAlive <pid>: true while pid is a live (non-zombie) process.
processAlive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
  case "$st" in Z*| "") return 1 ;; esac
  return 0
}

# --- 1, 11, 13. Production-only fix that passes: green, exit 0. ---
newCase green
HEAD_BEFORE=$(git -C "$REPO" rev-parse HEAD)
BRANCH_BEFORE=$(git -C "$REPO" symbolic-ref HEAD)
COUNT_BEFORE=$(git -C "$REPO" rev-list --all --count)
dispatchCase
expectResult "a passing production-only fix" 0 green ""
[ "$(claudeStarts)" = "1" ] || failCase "green: claude must start exactly once (got $(claudeStarts))"
expectLogHasRun "green" fix
# 13. No commit, HEAD unmoved.
[ "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE" ] || failCase "the script must not move HEAD"
[ "$(git -C "$REPO" symbolic-ref HEAD)" = "$BRANCH_BEFORE" ] || failCase "the script must not switch branch"
[ "$(git -C "$REPO" rev-list --all --count)" = "$COUNT_BEFORE" ] || failCase "the script must make no commit"
# The implementer's work is left in the working tree for the caller to judge.
[ "$(bash "$REPO/src/value.sh")" = "2" ] || failCase "green: the implementer's edit must remain in the working tree"
# claude runs in the repository with stdin closed.
[ "$(envValue PWD)" = "$REPO" ] || failCase "claude must run with the repository as its working directory (got '$(envValue PWD)')"
[ -z "$(envValue STDIN)" ] || failCase "claude must run with stdin closed; it read '$(envValue STDIN)'"

# --- 10. Endpoint and model come from the machine file. ---
newCase env-args
writeMachineFile '{"secondary": {"agent": "qwen", "model": "custom-qwen-model", "endpoint": "http://127.0.0.1:54321"}}'
printf 'custom-qwen-model:latest\n' >"$WORK/curl-models"
dispatchCase
expectResult "a custom endpoint and model" 0 green ""
[ "$(envValue BASE_URL)" = "http://127.0.0.1:54321" ] ||
  failCase "claude must get ANTHROPIC_BASE_URL=<machine endpoint> (got '$(envValue BASE_URL)')"
[ "$(envValue AUTH_TOKEN)" = "ollama" ] || failCase "claude must get ANTHROPIC_AUTH_TOKEN=ollama (got '$(envValue AUTH_TOKEN)')"
[ "$(envValue API_KEY_SET)" = "set" ] && [ -z "$(envValue API_KEY)" ] ||
  failCase "claude must get ANTHROPIC_API_KEY set and empty (set='$(envValue API_KEY_SET)', value='$(envValue API_KEY)')"
[ "$(argFollowing --model)" = "custom-qwen-model" ] ||
  failCase "claude's arguments must carry --model <machine model> (args: $(tr '\n' ' ' <"$WORK/claude-args"))"
grep -qxF -- "-p" "$WORK/claude-args" || failCase "claude must run headless with -p (args: $(tr '\n' ' ' <"$WORK/claude-args"))"
grep -qxF "Make tests/value_check.sh pass. Do not commit." "$WORK/claude-args" ||
  failCase "the prompt file's text must reach claude as an argument (args: $(tr '\n' ' ' <"$WORK/claude-args"))"
grep -qxF "http://127.0.0.1:54321/api/tags" "$WORK/curl-urls" 2>/dev/null ||
  failCase "the server check must GET <endpoint>/api/tags (urls: $(cat "$WORK/curl-urls" 2>/dev/null))"
# The caller's shell keeps its own values.
[ "$ANTHROPIC_BASE_URL" = "https://caller.example.invalid" ] || failCase "the caller's ANTHROPIC_BASE_URL changed"
CALLER_AFTER=$(
  bash -c 'bash "$0" "$@" >/dev/null 2>&1 </dev/null; printf "%s|%s|%s" "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN" "${ANTHROPIC_API_KEY-<unset>}"' \
    "$SCRIPT" --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$CASE_DIR/run2.log" --test-cmd "$TEST_CMD"
) || true
[ "$CALLER_AFTER" = "https://caller.example.invalid|caller-token-placeholder|<unset>" ] ||
  failCase "the calling shell's Anthropic variables must be unchanged after the script returns (got '$CALLER_AFTER')"
# Turn cap: default 60, QWEN_DISPATCH_MAX_TURNS overrides.
[ "$(argFollowing --max-turns)" = "60" ] || failCase "claude must get --max-turns 60 by default (got '$(argFollowing --max-turns)')"
newCase max-turns
QWEN_DISPATCH_MAX_TURNS=7 dispatchCase
expectResult "QWEN_DISPATCH_MAX_TURNS=7" 0 green ""
[ "$(argFollowing --max-turns)" = "7" ] || failCase "QWEN_DISPATCH_MAX_TURNS=7 must give --max-turns 7 (got '$(argFollowing --max-turns)')"

# --- 2, 11. Tests still fail: failed / tests-failed with the last 60 lines. ---
newCase tests-failed
echo wrong >"$WORK/claude-mode"
dispatchCase
expectResult "the test still failing" 1 failed tests-failed
printf '%s\n' "$TAIL" | grep -qF "VALUE-CHECK-FAILED: want 2 got 3" ||
  failCase "tests-failed: the test output's last line must follow from line 3 (got: '$TAIL')"
printf '%s\n' "$TAIL" | grep -qx "check-line-70" || failCase "tests-failed: the tail must include late output lines (got: '$TAIL')"
printf '%s\n' "$TAIL" | grep -qx "check-line-12" || failCase "tests-failed: the tail must hold the last 60 lines, from check-line-12 (got: '$TAIL')"
! printf '%s\n' "$TAIL" | grep -qx "check-line-11" || failCase "tests-failed: the tail must stop at 60 lines; check-line-11 is line 61 from the end"
[ "$(printf '%s\n' "$TAIL" | grep -vc "^transcript: ")" -le 60 ] || failCase "tests-failed: at most 60 test-output lines may follow line 2 (the transcript line is extra)"
expectLogHasRun "tests-failed" wrong

# --- 3. Edited tracked test file: touched-protected-path, even though tests pass. ---
newCase edit-test
echo edit-test >"$WORK/claude-mode"
dispatchCase
expectResult "an edited test file" 1 failed touched-protected-path
expectReasonNames "an edited test file" "tests/value_check.sh"
expectLogHasRun "edit-test" edit-test

# Judged against the RED sha, not HEAD: a test edit the run committed still counts.
newCase commit-test
echo commit-test >"$WORK/claude-mode"
dispatchCase
expectResult "a committed test edit" 1 failed touched-protected-path
expectReasonNames "a committed test edit" "tests/value_check.sh"

# --- 4. New untracked file under a test tree, a .test. file, and a spec. ---
newCase untracked-test-tree
echo untracked-test-tree >"$WORK/claude-mode"
dispatchCase
expectResult "a new untracked file under tests/" 1 failed touched-protected-path
expectReasonNames "a new untracked file under tests/" "tests/new_helper.sh"

newCase untracked-test-suffix
echo untracked-test-suffix >"$WORK/claude-mode"
dispatchCase
expectResult "a new untracked *.test.js file" 1 failed touched-protected-path
expectReasonNames "a new untracked *.test.js file" "src/value.test.js"

newCase edit-spec
echo edit-spec >"$WORK/claude-mode"
dispatchCase
expectResult "an edited spec" 1 failed touched-protected-path
expectReasonNames "an edited spec" "docs/specs/value.md"

# The lock pattern is protected too.
newCase write-lock
echo write-lock >"$WORK/claude-mode"
dispatchCase
expectResult "a written TDD lock" 1 failed touched-protected-path
expectReasonNames "a written TDD lock" ".claude/tdd-lock.json"

# --- 5, 11. Timeout: stopped, failed / timeout, no child left. ---
newCase timeout
echo slow >"$WORK/claude-mode"
T0=$(date +%s)
QWEN_DISPATCH_TIMEOUT_SECONDS=2 dispatchCase
ELAPSED=$(($(date +%s) - T0))
expectResult "a run past the timeout" 1 failed timeout
[ "$ELAPSED" -lt 20 ] || failCase "timeout: QWEN_DISPATCH_TIMEOUT_SECONDS=2 must stop the run early (took ${ELAPSED}s; the stub sleeps 30s)"
[ -f "$WORK/slow-child-pid" ] || failCase "setup: the slow stub never recorded its child"
SLOW_CHILD=$(cat "$WORK/slow-child-pid")
SLOW_STUB=$(cat "$WORK/slow-stub-pid")
# Up to 3 s for the kernel to reap what the script killed.
n=0
while { processAlive "$SLOW_CHILD" || processAlive "$SLOW_STUB"; } && [ "$n" -lt 30 ]; do
  sleep 0.1
  n=$((n + 1))
done
! processAlive "$SLOW_STUB" || failCase "timeout: the claude process ($SLOW_STUB) must be stopped"
! processAlive "$SLOW_CHILD" || failCase "timeout: claude's child process ($SLOW_CHILD) must not outlive the script"
expectLogHasRun "timeout" slow

# --- 6, 11. claude exits nonzero: failed / process-error. ---
newCase crash
echo crash >"$WORK/claude-mode"
dispatchCase
expectResult "claude exiting 3" 1 failed process-error
expectLogHasRun "process-error" crash

# --- 7. No usable secondary: unavailable / no-secondary-configured, claude never starts. ---
newCase no-machine-file
export AGENT_TIER_ASSIGNMENTS_FILE="$CASE_DIR/no-such-machine-file.json"
dispatchCase
expectResult "no machine file" 3 unavailable no-secondary-configured
expectClaudeNeverStarted "no machine file"

newCase no-secondary
writeMachineFile '{"primary": {"agent": "claude"}}'
dispatchCase
expectResult "no secondary entry" 3 unavailable no-secondary-configured
expectClaudeNeverStarted "no secondary entry"

for other in claude gemini; do
  newCase "secondary-$other"
  writeMachineFile "{\"primary\": {\"agent\": \"claude\"}, \"secondary\": {\"agent\": \"$other\", \"model\": \"qwen-coder-local\", \"endpoint\": \"http://127.0.0.1:11434\"}}"
  dispatchCase
  expectResult "secondary agent $other" 3 unavailable no-secondary-configured
  expectClaudeNeverStarted "secondary agent $other"
done

# HOME and AGENT_TIER_ASSIGNMENTS_FILE both unset: there is no machine file to
# read, so the result is still unavailable / no-secondary-configured, exit 3.
# env -u HOME keeps the case off the real ~/.claude.
newCase home-unset
RC=0
OUT=$(printf 'STDIN-LEAK\n' | env -u HOME -u AGENT_TIER_ASSIGNMENTS_FILE bash "$SCRIPT" \
  --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD" 2>"$WORK/err") || RC=$?
ERR=$(cat "$WORK/err")
STATUS=$(printf '%s\n' "$OUT" | sed -n 1p)
REASON=$(printf '%s\n' "$OUT" | sed -n 2p)
expectResult "HOME unset" 3 unavailable no-secondary-configured
[ "$REASON" = "no-secondary-configured" ] || failCase "HOME unset: line 2 must be exactly 'no-secondary-configured' (got '$REASON')"
expectClaudeNeverStarted "HOME unset"

# --- 8. Endpoint does not answer: unavailable / server-unreachable. ---
newCase server-down
echo down >"$WORK/curl-mode"
dispatchCase
expectResult "an unreachable endpoint" 3 unavailable server-unreachable
expectClaudeNeverStarted "an unreachable endpoint"

# --- 9. Server lists other models only: unavailable / model-missing. ---
newCase model-missing
printf 'other-model:latest\nqwen-coder-local-v2:latest\n' >"$WORK/curl-models"
dispatchCase
expectResult "a server without the model" 3 unavailable model-missing
expectClaudeNeverStarted "a server without the model"

# --- 12. Usage errors exit 2, explain on stderr, and never start claude. ---
# expectUsage <what> <args...>
expectUsage() {
  local what="$1"
  shift
  rm -f "$WORK/claude-starts"
  dispatch "$@"
  [ "$RC" -eq 2 ] || failCase "$what: must exit 2 (got $RC, stdout '$OUT', stderr '$ERR')"
  [ -n "$ERR" ] || failCase "$what: must explain on stderr"
  expectClaudeNeverStarted "$what"
}
newCase usage
expectUsage "missing --repo" --red "$RED" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
expectUsage "missing --red" --repo "$REPO" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
expectUsage "missing --prompt" --repo "$REPO" --red "$RED" --log "$LOG" --test-cmd "$TEST_CMD"
expectUsage "missing --log" --repo "$REPO" --red "$RED" --prompt "$PROMPT" --test-cmd "$TEST_CMD"
expectUsage "missing --test-cmd" --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG"
expectUsage "no arguments"
expectUsage "--test-cmd with no value" --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" --test-cmd
expectUsage "an unknown argument" --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD" --bogus x
expectUsage "a --red that names no object" --repo "$REPO" --red 0123456789abcdef0123456789abcdef01234567 \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
expectUsage "a --red that is not a revision" --repo "$REPO" --red not-a-revision \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
BLOB=$(printf 'a blob, not a commit\n' | git -C "$REPO" hash-object -w --stdin)
expectUsage "a --red that is a blob" --repo "$REPO" --red "$BLOB" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
TREE=$(git -C "$REPO" rev-parse "HEAD^{tree}")
expectUsage "a --red that is a tree" --repo "$REPO" --red "$TREE" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
expectUsage "a --prompt file that does not exist" --repo "$REPO" --red "$RED" --prompt "$CASE_DIR/no-such-prompt.txt" \
  --log "$LOG" --test-cmd "$TEST_CMD"

# --- Negative input: nonexistent repo, metacharacters, oversized values. ---
expectUsage "a nonexistent --repo" --repo "$CASE_DIR/no-such-repo" --red "$RED" --prompt "$PROMPT" \
  --log "$LOG" --test-cmd "$TEST_CMD"
mkdir -p "$CASE_DIR/not-a-repo"
expectUsage "a --repo that is not a git repository" --repo "$CASE_DIR/not-a-repo" --red "$RED" \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
expectUsage "a --repo with a command separator" --repo "$REPO; touch $WORK/pwned1" --red "$RED" \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
[ ! -e "$WORK/pwned1" ] || failCase "a ';' in --repo must never run a command"
expectUsage "a --repo with command substitution" --repo "\$(touch $WORK/pwned2)" --red "$RED" \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
[ ! -e "$WORK/pwned2" ] || failCase "a command substitution in --repo must never run"
expectUsage "a --red with a command separator" --repo "$REPO" --red "$RED; touch $WORK/pwned3" \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
[ ! -e "$WORK/pwned3" ] || failCase "a ';' in --red must never run a command"
expectUsage "a --red with backticks" --repo "$REPO" --red "\`touch $WORK/pwned4\`" \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
[ ! -e "$WORK/pwned4" ] || failCase "a backtick in --red must never run"
expectUsage "a --red that is a git option" --repo "$REPO" --red "--output=$WORK/pwned5" \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
[ ! -e "$WORK/pwned5" ] || failCase "a --red that looks like a git option must never reach git as one"
BIG=$(head -c 5000 /dev/zero | tr '\0' a)
expectUsage "an oversized --red" --repo "$REPO" --red "$BIG" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
# A usage error never runs the test command.
expectUsage "a bad --red with a marking test command" --repo "$REPO" --red not-a-revision \
  --prompt "$PROMPT" --log "$LOG" --test-cmd "touch $WORK/testcmd-ran"
[ ! -e "$WORK/testcmd-ran" ] || failCase "a usage error must not run the test command"

# Metacharacters in the prompt file reach claude as text and never run.
newCase prompt-metachar
printf 'Fix it. $(touch %s/pwned6) `touch %s/pwned7` ; touch %s/pwned8\n' "$WORK" "$WORK" "$WORK" >"$PROMPT"
dispatchCase
expectResult "a prompt with shell metacharacters" 0 green ""
[ ! -e "$WORK/pwned6" ] && [ ! -e "$WORK/pwned7" ] && [ ! -e "$WORK/pwned8" ] ||
  failCase "shell metacharacters in the prompt file must never run"
grep -qxF "$(cat "$PROMPT")" "$WORK/claude-args" || failCase "the prompt must reach claude verbatim (args: $(tr '\n' ' ' <"$WORK/claude-args"))"

# The test command runs exactly as given, in the repository: a compound
# command is the caller's own and runs whole, and the script adds nothing.
newCase test-cmd-compound
TEST_CMD="bash tests/value_check.sh && pwd -P >\"$WORK/testcmd-pwd\""
dispatchCase
expectResult "a compound test command" 0 green ""
[ "$(cat "$WORK/testcmd-pwd" 2>/dev/null)" = "$REPO" ] || failCase "the test command must run with the repository as its working directory"

# --- 14. The protected-path check fails closed. ---
# claude would run a production-only fix and the test command would pass, so
# only an unusable role policy stands between the run and green. The policy is
# checked before the run, so claude never starts (IAN-701).
# expectPolicyUnreadable <what> <policy file>
expectPolicyUnreadable() {
  newCase "policy-$1"
  CLAUDE_ROLE_POLICY_FILE="$2" dispatchCase
  expectResult "a role policy that is $1" 1 failed policy-unreadable
  expectClaudeNeverStarted "a role policy that is $1"
}
newCase policy-setup
POLICY_DIR="$CASE_DIR"
expectPolicyUnreadable missing "$POLICY_DIR/no-such-policy.json"
printf '{"patterns": {"tests": "(^|/)tests/"' >"$POLICY_DIR/truncated.json"
expectPolicyUnreadable not-json "$POLICY_DIR/truncated.json"
printf 'not json at all\n' >"$POLICY_DIR/garbage.json"
expectPolicyUnreadable garbage "$POLICY_DIR/garbage.json"
printf '{}\n' >"$POLICY_DIR/empty-object.json"
expectPolicyUnreadable empty-object "$POLICY_DIR/empty-object.json"
printf '{"patterns": {"any": "."}}\n' >"$POLICY_DIR/no-protected-patterns.json"
expectPolicyUnreadable without-protected-patterns "$POLICY_DIR/no-protected-patterns.json"
cp "$CLAUDE_HARNESS_ROOT/enforce/role-policy.json" "$POLICY_DIR/unreadable.json"
chmod 000 "$POLICY_DIR/unreadable.json"
# root reads a mode-000 file anyway; the case only means something otherwise.
if ! [ -r "$POLICY_DIR/unreadable.json" ]; then
  expectPolicyUnreadable unreadable "$POLICY_DIR/unreadable.json"
fi
chmod 600 "$POLICY_DIR/unreadable.json"

# --- 15. The test command has a time cap. ---
# claude returns at once; the test command starts a 30 s sleeping child and
# waits on it. The script runs under this test's own 15 s watchdog, so a
# script with no cap fails here instead of hanging.
newCase test-cmd-timeout
TEST_CMD="echo \$\$ >\"$WORK/testcmd-shell-pid\"; echo \$\$ >>\"$WORK/stub-pids\"; sleep 30 & echo \$! >\"$WORK/testcmd-child-pid\"; echo \$! >>\"$WORK/stub-pids\"; wait"
rm -f "$WORK/testcmd-shell-pid" "$WORK/testcmd-child-pid"
T0=$(date +%s)
QWEN_DISPATCH_TIMEOUT_SECONDS=2 bash "$SCRIPT" --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" \
  --test-cmd "$TEST_CMD" </dev/null >"$CASE_DIR/out" 2>"$CASE_DIR/err" &
SCRIPT_PID=$!
n=0
while kill -0 "$SCRIPT_PID" 2>/dev/null && [ "$n" -lt 150 ]; do
  sleep 0.1
  n=$((n + 1))
done
if kill -0 "$SCRIPT_PID" 2>/dev/null; then
  kill -9 "$SCRIPT_PID" 2>/dev/null || true
  failCase "test-cmd timeout: QWEN_DISPATCH_TIMEOUT_SECONDS=2 must stop a test command that runs 30 s; the script was still running after 15 s"
fi
RC=0
wait "$SCRIPT_PID" || RC=$?
ELAPSED=$(($(date +%s) - T0))
OUT=$(cat "$CASE_DIR/out")
ERR=$(cat "$CASE_DIR/err")
STATUS=$(printf '%s\n' "$OUT" | sed -n 1p)
REASON=$(printf '%s\n' "$OUT" | sed -n 2p)
expectResult "a test command past the timeout" 1 failed timeout
[ "$ELAPSED" -lt 15 ] || failCase "test-cmd timeout: the run took ${ELAPSED}s; the cap is 2 s and the child sleeps 30 s"
[ "$(claudeStarts)" = "1" ] || failCase "test-cmd timeout: claude must start exactly once (got $(claudeStarts))"
[ -f "$WORK/testcmd-child-pid" ] || failCase "setup: the test command never started its sleeping child"
TC_CHILD=$(cat "$WORK/testcmd-child-pid")
TC_SHELL=$(cat "$WORK/testcmd-shell-pid")
n=0
while { processAlive "$TC_CHILD" || processAlive "$TC_SHELL"; } && [ "$n" -lt 30 ]; do
  sleep 0.1
  n=$((n + 1))
done
! processAlive "$TC_SHELL" || failCase "test-cmd timeout: the test command's shell ($TC_SHELL) must be stopped"
! processAlive "$TC_CHILD" || failCase "test-cmd timeout: the test command's child ($TC_CHILD) must not outlive the script"

# --- 16. Qwen gets the slim implementer rules, never the user's CLAUDE.md. ---
# The full CLAUDE.md holds orchestrator rules (turn summaries, PRs, tickets,
# routing) that a small local model wrongly obeys. The script appends
# enforce/qwen-implementer-rules.md, resolved next to the script, instead;
# QWEN_IMPLEMENTER_RULES_FILE overrides that path.
unset QWEN_IMPLEMENTER_RULES_FILE
SLIM_RULES="$CLAUDE_HARNESS_ROOT/enforce/qwen-implementer-rules.md"
SLIM_RULES_DIR=$(cd -P "$CLAUDE_HARNESS_ROOT/enforce" && pwd -P)

# physicalPath <path>: prints <path> with its directory resolved physically,
# or the path unchanged when its directory does not exist.
physicalPath() {
  local dir
  if dir=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "$dir" "$(basename "$1")"
  else
    printf '%s\n' "$1"
  fi
}

# sandboxHome: makes a HOME for the case that holds a full .claude/CLAUDE.md,
# and prints its path.
sandboxHome() {
  mkdir -p "$CASE_DIR/home/.claude"
  printf '# Global Rules\n\nEnd every turn with **Done:**, **Decide:** and **Next:**.\n' \
    >"$CASE_DIR/home/.claude/CLAUDE.md"
  printf '%s\n' "$CASE_DIR/home"
}

newCase slim-rules-default
SANDBOX_HOME=$(sandboxHome)
HOME="$SANDBOX_HOME" dispatchCase
expectResult "the default implementer rules" 0 green ""
ARGS_TEXT=$(tr '\n' ' ' <"$WORK/claude-args")
! grep -Eq 'CLAUDE\.md$' "$WORK/claude-args" ||
  failCase "slim rules: claude's arguments must never carry a path ending in CLAUDE.md, even when \$HOME/.claude/CLAUDE.md exists (args: $ARGS_TEXT)"
APPENDED=$(argFollowing --append-system-prompt-file)
[ -n "$APPENDED" ] || failCase "slim rules: claude must get --append-system-prompt-file <rules file> (args: $ARGS_TEXT)"
[ "$(physicalPath "$APPENDED")" = "$SLIM_RULES_DIR/qwen-implementer-rules.md" ] ||
  failCase "slim rules: --append-system-prompt-file must name $SLIM_RULES (got '$APPENDED')"

newCase slim-rules-override
SANDBOX_HOME=$(sandboxHome)
printf '# Implementer rules\n\nOverride copy.\n' >"$CASE_DIR/override-rules.md"
HOME="$SANDBOX_HOME" QWEN_IMPLEMENTER_RULES_FILE="$CASE_DIR/override-rules.md" dispatchCase
expectResult "QWEN_IMPLEMENTER_RULES_FILE set to a temp file" 0 green ""
[ "$(argFollowing --append-system-prompt-file)" = "$CASE_DIR/override-rules.md" ] ||
  failCase "QWEN_IMPLEMENTER_RULES_FILE must set the --append-system-prompt-file path (got '$(argFollowing --append-system-prompt-file)'; args: $(tr '\n' ' ' <"$WORK/claude-args"))"
! grep -Eq 'CLAUDE\.md$' "$WORK/claude-args" ||
  failCase "QWEN_IMPLEMENTER_RULES_FILE: claude's arguments must never carry a path ending in CLAUDE.md (args: $(tr '\n' ' ' <"$WORK/claude-args"))"

# A missing rules file: unavailable / rules-missing, after the machine-file
# and server checks pass (newCase sets up both), and claude never starts.
newCase slim-rules-missing
SANDBOX_HOME=$(sandboxHome)
HOME="$SANDBOX_HOME" QWEN_IMPLEMENTER_RULES_FILE="$CASE_DIR/no-such-rules.md" dispatchCase
expectResult "a missing implementer rules file" 3 unavailable rules-missing
[ "$REASON" = "rules-missing" ] || failCase "a missing implementer rules file: line 2 must be exactly 'rules-missing' (got '$REASON')"
expectClaudeNeverStarted "a missing implementer rules file"

# --- 17. The shipped implementer rules file is short and implementer-only. ---
[ -f "$SLIM_RULES" ] || failCase "the implementer rules file must ship at $SLIM_RULES (not created yet)"
[ -s "$SLIM_RULES" ] || failCase "the implementer rules file $SLIM_RULES must not be empty"
RULES_LINES=$(wc -l <"$SLIM_RULES" | tr -d ' ')
[ "$RULES_LINES" -le 80 ] || failCase "the implementer rules file must be at most 80 lines (got $RULES_LINES)"
for marker in '**Done:**' '**Decide:**' '**Next:**' 'pr-reviewer' 'route.sh' 'Linear' 'ticket'; do
  ! grep -qF -- "$marker" "$SLIM_RULES" ||
    failCase "the implementer rules file must not carry the orchestrator marker '$marker' (line: $(grep -nF -- "$marker" "$SLIM_RULES" | head -1))"
done
grep -qxF '# Implementer rules' "$SLIM_RULES" || failCase "the implementer rules file must hold the heading line '# Implementer rules'"
grep -qi 'reuse' "$SLIM_RULES" || failCase "the implementer rules file must tell the implementer to reuse existing code ('reuse')"
grep -qi 'do not commit' "$SLIM_RULES" || failCase "the implementer rules file must say 'do not commit'"
grep -qi 'do not edit' "$SLIM_RULES" || failCase "the implementer rules file must say 'do not edit' (the tests)"

# --- 18. Idle watchdog: a Claude run whose --log stops growing is stopped. ---
# QWEN_DISPATCH_IDLE_SECONDS (default 600, 0 disables) bounds how long the
# --log file may go without growing while claude runs. When it fires the whole
# process group is stopped and the result is failed / stalled, exit 1. It
# covers only the Claude run, never the final test command, and the overall
# QWEN_DISPATCH_TIMEOUT_SECONDS still applies.

# dispatchBounded <seconds> [VAR=value ...]: runs the script in the background
# with the case's full argument set and the given environment, under this
# test's own watchdog, so a script without the idle watchdog fails the case
# instead of hanging. Sets RC, OUT, ERR, STATUS, REASON and ELAPSED.
dispatchBounded() {
  local limit="$1" n=0 pid t0
  shift
  t0=$(date +%s)
  env "$@" bash "$SCRIPT" --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" \
    --test-cmd "$TEST_CMD" </dev/null >"$CASE_DIR/out" 2>"$CASE_DIR/err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt $((limit * 10)) ]; do
    sleep 0.1
    n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    failCase "${CASE_DIR##*/}: the script was still running after this test's ${limit} s limit (env: $*; stdout so far: '$(cat "$CASE_DIR/out")')"
  fi
  RC=0
  wait "$pid" || RC=$?
  ELAPSED=$(($(date +%s) - t0))
  OUT=$(cat "$CASE_DIR/out")
  ERR=$(cat "$CASE_DIR/err")
  STATUS=$(printf '%s\n' "$OUT" | sed -n 1p)
  REASON=$(printf '%s\n' "$OUT" | sed -n 2p)
}

# expectStubGone <what>: the stub and its sleeping child (recorded by the
# slow and silent-hang modes) are gone, allowing 3 s for reaping.
expectStubGone() {
  local child stub n=0
  [ -f "$WORK/slow-child-pid" ] || failCase "setup: $1: the stub never recorded its child"
  child=$(cat "$WORK/slow-child-pid")
  stub=$(cat "$WORK/slow-stub-pid")
  while { processAlive "$child" || processAlive "$stub"; } && [ "$n" -lt 30 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  ! processAlive "$stub" || failCase "$1: the claude process ($stub) must be stopped"
  ! processAlive "$child" || failCase "$1: claude's child process ($child) must not outlive the script"
}

# 18.1 Output then silence: stopped well before the stub's 30 s sleep.
newCase idle-stalled
echo slow >"$WORK/claude-mode"
dispatchBounded 15 QWEN_DISPATCH_TIMEOUT_SECONDS=100 QWEN_DISPATCH_IDLE_SECONDS=2
expectResult "a run whose log stops growing" 1 failed stalled
[ "$REASON" = "stalled" ] || failCase "idle stalled: line 2 must be exactly 'stalled' (got '$REASON')"
[ "$ELAPSED" -lt 15 ] || failCase "idle stalled: QWEN_DISPATCH_IDLE_SECONDS=2 must stop the run early (took ${ELAPSED}s)"
expectStubGone "idle stalled"
expectLogHasRun "idle stalled" slow

# 18.2 A log that keeps growing is not stalled, even past the idle limit.
newCase idle-trickle
echo trickle-fix >"$WORK/claude-mode"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=100 QWEN_DISPATCH_IDLE_SECONDS=2
expectResult "a run that writes every second for 6 s" 0 green ""
grep -q "STUB-CLAUDE-TRICKLE-6" "$LOG" || failCase "idle trickle: the stub must have run to its last line (log: $(head -c 2000 "$LOG"))"

# 18.3 The idle clock starts with claude: no output at all is a stall.
newCase idle-silent
echo silent-hang >"$WORK/claude-mode"
dispatchBounded 15 QWEN_DISPATCH_TIMEOUT_SECONDS=100 QWEN_DISPATCH_IDLE_SECONDS=2
expectResult "a run that never writes" 1 failed stalled
[ "$REASON" = "stalled" ] || failCase "idle silent: line 2 must be exactly 'stalled' (got '$REASON')"
[ "$ELAPSED" -lt 15 ] || failCase "idle silent: QWEN_DISPATCH_IDLE_SECONDS=2 must stop a silent run early (took ${ELAPSED}s)"
expectStubGone "idle silent"

# 18.4 0 disables the watchdog; the default (unset) does not fire within 3 s.
newCase idle-disabled
echo silent-then-fix >"$WORK/claude-mode"
echo 4 >"$WORK/claude-sleep"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=100 QWEN_DISPATCH_IDLE_SECONDS=0
expectResult "QWEN_DISPATCH_IDLE_SECONDS=0 and a 4 s silent run" 0 green ""

newCase idle-default
echo silent-then-fix >"$WORK/claude-mode"
echo 3 >"$WORK/claude-sleep"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=100
expectResult "QWEN_DISPATCH_IDLE_SECONDS unset and a 3 s silent run" 0 green ""

# A value that is not a whole number is a usage error and never starts claude.
newCase idle-usage
QWEN_DISPATCH_IDLE_SECONDS=abc expectUsage "QWEN_DISPATCH_IDLE_SECONDS=abc" \
  --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"
QWEN_DISPATCH_IDLE_SECONDS=-1 expectUsage "QWEN_DISPATCH_IDLE_SECONDS=-1" \
  --repo "$REPO" --red "$RED" --prompt "$PROMPT" --log "$LOG" --test-cmd "$TEST_CMD"

# 18.5 The overall timeout wins when it comes first.
newCase idle-timeout-first
echo silent-hang >"$WORK/claude-mode"
dispatchBounded 15 QWEN_DISPATCH_TIMEOUT_SECONDS=2 QWEN_DISPATCH_IDLE_SECONDS=100
expectResult "a silent run with timeout 2 and idle 100" 1 failed timeout
[ "$REASON" = "timeout" ] || failCase "idle timeout-first: line 2 must be exactly 'timeout', not 'stalled' (got '$REASON')"
expectStubGone "idle timeout-first"

# 18.6 The idle watch covers only the Claude run, not the final test command.
newCase idle-test-cmd
TEST_CMD="sleep 4 && bash tests/value_check.sh"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=100 QWEN_DISPATCH_IDLE_SECONDS=2
expectResult "a test command silent for 4 s with idle 2" 0 green ""

# 19. Only the PreToolUse and PostToolUse hook events reach claude through
# --settings. Stop, SubagentStop, SessionStart and every non-hook key of the
# user settings stay out. The --settings file lives in the script's scratch
# directory and is gone when the script exits, so a wrapper stub, first on PATH
# for these cases only, copies it to $WORK/claude-settings before running the
# stub claude.
SETTINGS_STUBS="$WORK/settings-stubs"
mkdir -p "$SETTINGS_STUBS"
cat >"$SETTINGS_STUBS/claude" <<EOF
#!/usr/bin/env bash
W="$WORK"
INNER="$STUBS/claude"
EOF
cat >>"$SETTINGS_STUBS/claude" <<'EOF'
prev=""
for a in "$@"; do
  if [ "$prev" = "--settings" ] && [ -f "$a" ]; then cp "$a" "$W/claude-settings"; fi
  prev="$a"
done
exec "$INNER" "$@"
EOF
chmod +x "$SETTINGS_STUBS/claude"
PATH_BEFORE_SETTINGS="$PATH"
export PATH="$SETTINGS_STUBS:$PATH"

# settingsCase <name> <settings json or empty for a missing file>: a fresh case
# whose user settings file holds the JSON; an empty argument names a path that
# does not exist.
settingsCase() {
  newCase "$1"
  rm -f "$WORK/claude-settings"
  USER_SETTINGS_FILE="$CASE_DIR/user-settings.json"
  if [ -n "$2" ]; then
    printf '%s\n' "$2" >"$USER_SETTINGS_FILE"
    jq -e . "$USER_SETTINGS_FILE" >/dev/null || failCase "setup: settings JSON is malformed: $2"
  fi
}

# passedSettings <what>: prints the JSON claude received through --settings.
passedSettings() {
  grep -qx -- "--settings" "$WORK/claude-args" || failCase "$1: --settings must be passed (args: $(tr '\n' ' ' <"$WORK/claude-args"))"
  [ -f "$WORK/claude-settings" ] || failCase "$1: the --settings file must exist while claude runs"
  cat "$WORK/claude-settings"
}

PRE_HOOK='[{"matcher":"Bash","hooks":[{"type":"command","command":"/guards/pre.sh"}]}]'
POST_HOOK='[{"matcher":"*","hooks":[{"type":"command","command":"/guards/redact.sh","timeout":5}]}]'
OTHER_HOOK='[{"hooks":[{"type":"command","command":"/guards/orchestrator-only.sh"}]}]'

# 19.1 All five events: only PreToolUse and PostToolUse pass, unchanged (criterion 1).
# 19.2 Nothing but hooks: env, permissions, model and enabledPlugins stay out (criterion 2).
settingsCase settings-five-events "{\"env\":{\"SOME_FLAG\":\"1\"},\"permissions\":{\"allow\":[\"Bash(ls)\"]},\"model\":\"opus\",\"enabledPlugins\":{\"x@y\":true},\"hooks\":{\"PreToolUse\":$PRE_HOOK,\"PostToolUse\":$POST_HOOK,\"Stop\":$OTHER_HOOK,\"SubagentStop\":$OTHER_HOOK,\"SessionStart\":$OTHER_HOOK}}"
CLAUDE_SETTINGS_FILE="$USER_SETTINGS_FILE" dispatchCase
expectResult "settings with five hook events" 0 green ""
GOT_SETTINGS=$(passedSettings "five events")
GOT_TOP=$(printf '%s' "$GOT_SETTINGS" | jq -c 'keys')
GOT_KEYS=$(printf '%s' "$GOT_SETTINGS" | jq -c '.hooks | keys')
[ "$GOT_KEYS" = '["PostToolUse","PreToolUse"]' ] ||
  failCase "five events: .hooks must hold exactly PreToolUse and PostToolUse (got $GOT_KEYS)"
[ "$(printf '%s' "$GOT_SETTINGS" | jq -c '.hooks.PreToolUse')" = "$(printf '%s' "$PRE_HOOK" | jq -c .)" ] ||
  failCase "five events: PreToolUse must pass unchanged (got $(printf '%s' "$GOT_SETTINGS" | jq -c '.hooks.PreToolUse'))"
[ "$(printf '%s' "$GOT_SETTINGS" | jq -c '.hooks.PostToolUse')" = "$(printf '%s' "$POST_HOOK" | jq -c .)" ] ||
  failCase "five events: PostToolUse must pass unchanged (got $(printf '%s' "$GOT_SETTINGS" | jq -c '.hooks.PostToolUse'))"
[ "$GOT_TOP" = '["hooks"]' ] ||
  failCase "five events: the passed settings must have exactly one top-level key, hooks (got $GOT_TOP)"

# 19.3 Only dropped events: --settings still passes, with .hooks {} (criterion 3).
settingsCase settings-dropped-only "{\"model\":\"opus\",\"hooks\":{\"Stop\":$OTHER_HOOK,\"SessionStart\":$OTHER_HOOK}}"
CLAUDE_SETTINGS_FILE="$USER_SETTINGS_FILE" dispatchCase
expectResult "settings with only dropped events" 0 green ""
GOT_SETTINGS=$(passedSettings "dropped only")
GOT_HOOKS=$(printf '%s' "$GOT_SETTINGS" | jq -c '.hooks')
[ "$GOT_HOOKS" = '{}' ] || failCase "dropped only: .hooks must be {} (got $GOT_HOOKS)"
[ "$(printf '%s' "$GOT_SETTINGS" | jq -c 'keys')" = '["hooks"]' ] ||
  failCase "dropped only: the passed settings must have exactly one top-level key, hooks"

# 19.4 No hooks key: --settings still passes, with .hooks {} and not null (criterion 4).
settingsCase settings-no-hooks '{"model":"opus","env":{"SOME_FLAG":"1"}}'
CLAUDE_SETTINGS_FILE="$USER_SETTINGS_FILE" dispatchCase
expectResult "settings with no hooks key" 0 green ""
GOT_SETTINGS=$(passedSettings "no hooks key")
GOT_HOOKS=$(printf '%s' "$GOT_SETTINGS" | jq -c '.hooks')
[ "$GOT_HOOKS" = '{}' ] || failCase "no hooks key: .hooks must be {} (got $GOT_HOOKS)"

# 19.5 A missing user settings file: no --settings argument (criterion 5).
settingsCase settings-missing ""
[ ! -e "$USER_SETTINGS_FILE" ] || failCase "setup: the missing settings file must not exist"
CLAUDE_SETTINGS_FILE="$USER_SETTINGS_FILE" dispatchCase
expectResult "a missing settings file" 0 green ""
! grep -qx -- "--settings" "$WORK/claude-args" ||
  failCase "missing settings: --settings must not be passed (args: $(tr '\n' ' ' <"$WORK/claude-args"))"
[ ! -f "$WORK/claude-settings" ] || failCase "missing settings: no settings file may reach claude"

export PATH="$PATH_BEFORE_SETTINGS"

# --- 20. LOW review findings (IAN-701). ---
# Every case runs through dispatchBounded, so a hang fails the case instead of
# the suite. Extra stub behaviour comes from a wrapper claude, first on PATH
# for these cases only: it runs the stub claude (mode fix unless set), then
# performs the action named in $WORK/claude-extra in the repository, and exits
# with the stub's status.
EXTRA_STUBS="$WORK/extra-stubs"
mkdir -p "$EXTRA_STUBS"
cat >"$EXTRA_STUBS/claude" <<EOF
#!/usr/bin/env bash
W="$WORK"
INNER="$STUBS/claude"
EOF
cat >>"$EXTRA_STUBS/claude" <<'EOF'
rc=0
"$INNER" "$@" || rc=$?
extra=$(cat "$W/claude-extra" 2>/dev/null || echo none)
case "$extra" in
  ctrl-name)
    printf 'echo bad\n' >"tests/bad"$'\n'"name"$'\a'".sh"
    ;;
  commit-production)
    git add -A >/dev/null 2>&1
    git -c core.hooksPath=/dev/null -c user.email=s@s -c user.name=s commit -qm "stub commit" >/dev/null 2>&1
    ;;
  reset-soft)
    git reset -q --soft HEAD~1 >/dev/null 2>&1
    ;;
  break-git)
    # The repository's .git becomes a gitfile naming a directory that does not
    # exist, so every later git command in the repository fails.
    mv .git .git-moved-by-stub
    printf 'gitdir: %s\n' "$W/no-such-gitdir" >.git
    ;;
esac
exit "$rc"
EOF
chmod +x "$EXTRA_STUBS/claude"
export PATH="$EXTRA_STUBS:$PATH"

# extraCase <name> <action>: a fresh case whose wrapper claude performs <action>.
extraCase() {
  newCase "$1"
  printf '%s\n' "$2" >"$WORK/claude-extra"
}

# writePolicy <file> <json>: writes a role policy for one case.
writePolicy() {
  printf '%s\n' "$2" >"$1"
  jq -e . "$1" >/dev/null || failCase "setup: policy JSON is malformed: $2"
}
FULL_TESTS=$(jq -r .patterns.tests "$CLAUDE_HARNESS_ROOT/enforce/role-policy.json")
FULL_SPECS=$(jq -r .patterns.specs "$CLAUDE_HARNESS_ROOT/enforce/role-policy.json")
FULL_LOCK=$(jq -r .patterns.lock "$CLAUDE_HARNESS_ROOT/enforce/role-policy.json")

# 20.1 A relative --log resolves against the caller's working directory, once.
# Both the caller and the repository hold an out/ directory, so a script that
# opens the log once in each place writes its run log inside the repository.
extraCase relative-log none
CALLER_DIR="$CASE_DIR/caller"
mkdir -p "$CALLER_DIR/out" "$REPO/out"
RETURN_DIR=$(pwd)
cd "$CALLER_DIR"
LOG="out/run.log"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20
cd "$RETURN_DIR"
expectResult "a relative --log" 0 green ""
[ ! -e "$REPO/out/run.log" ] ||
  failCase "relative --log: no log may appear inside the repository, but $REPO/out/run.log exists (it holds: $(head -c 300 "$REPO/out/run.log"))"
STRAY_LOGS=$(find "$REPO" -name run.log -not -path '*/.git/*' 2>/dev/null)
[ -z "$STRAY_LOGS" ] || failCase "relative --log: no run.log may appear in the repository tree (found: $STRAY_LOGS)"
LOG="$CALLER_DIR/out/run.log"
expectLogHasRun "relative --log at <caller cwd>/out/run.log" fix

# 20.2 A changed protected path whose name holds a newline and a BEL: stdout is
# exactly two lines and line 2 carries no control character.
extraCase ctrl-name ctrl-name
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20
expectResult "a protected file named with a newline and a BEL" 1 failed touched-protected-path
OUT_LINES=$(printf '%s\n' "$OUT" | grep -v '^transcript: ' | wc -l | tr -d ' ')
[ "$OUT_LINES" = "2" ] ||
  failCase "control-character name: stdout must be exactly two lines (got $OUT_LINES: '$(printf '%s' "$OUT" | od -c | head -5 | tr '\n' ' ')')"
! printf '%s' "$REASON" | LC_ALL=C grep -q '[[:cntrl:]]' ||
  failCase "control-character name: line 2 must hold no control character (got: $(printf '%s' "$REASON" | od -c | tr '\n' ' '))"

# 20.3 HEAD moved during the run: failed / head-moved, even with passing tests.
extraCase head-commit commit-production
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20
expectResult "a run that commits a production-only fix" 1 failed head-moved
[ "$REASON" = "head-moved" ] || failCase "head moved by a commit: line 2 must be exactly 'head-moved' (got '$REASON')"

# A reset moves HEAD too. The case starts one non-protected commit past RED so
# the stub has a commit to reset away; the fix stays in the working tree.
extraCase head-reset reset-soft
printf 'notes\n' >"$REPO/notes.txt"
git -C "$REPO" add notes.txt
git -C "$REPO" commit -qm "notes past RED"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20
expectResult "a run that resets HEAD" 1 failed head-moved
[ "$REASON" = "head-moved" ] || failCase "head moved by a reset: line 2 must be exactly 'head-moved' (got '$REASON')"

# HEAD past RED at the start but left alone by the run is not a move.
extraCase head-past-red-unmoved none
printf 'notes\n' >"$REPO/notes.txt"
git -C "$REPO" add notes.txt
git -C "$REPO" commit -qm "notes past RED"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20
expectResult "HEAD past RED before the run and unmoved by it" 0 green ""

# 20.4 A missing or unreadable user settings file: the run still starts without
# --settings, and stderr carries exactly one line naming 'no user hooks'.
extraCase settings-missing-warning none
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20 CLAUDE_SETTINGS_FILE="$CASE_DIR/no-such-settings.json"
expectResult "a missing user settings file" 0 green ""
[ "$(claudeStarts)" = "1" ] || failCase "missing settings warning: claude must still start once (got $(claudeStarts))"
! grep -qx -- "--settings" "$WORK/claude-args" ||
  failCase "missing settings warning: --settings must not be passed (args: $(tr '\n' ' ' <"$WORK/claude-args"))"
WARN_COUNT=$(printf '%s\n' "$ERR" | grep -c 'no user hooks' || true)
[ "$WARN_COUNT" = "1" ] ||
  failCase "missing settings warning: stderr must hold exactly one line containing 'no user hooks' (got $WARN_COUNT; stderr: '$ERR')"

extraCase settings-unreadable-warning none
printf '{"hooks":{}}\n' >"$CASE_DIR/locked-settings.json"
chmod 000 "$CASE_DIR/locked-settings.json"
# root reads a mode-000 file anyway; the case only means something otherwise.
if ! [ -r "$CASE_DIR/locked-settings.json" ]; then
  dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20 CLAUDE_SETTINGS_FILE="$CASE_DIR/locked-settings.json"
  chmod 600 "$CASE_DIR/locked-settings.json"
  expectResult "an unreadable user settings file" 0 green ""
  [ "$(claudeStarts)" = "1" ] || failCase "unreadable settings warning: claude must still start once (got $(claudeStarts))"
  WARN_COUNT=$(printf '%s\n' "$ERR" | grep -c 'no user hooks' || true)
  [ "$WARN_COUNT" = "1" ] ||
    failCase "unreadable settings warning: stderr must hold exactly one line containing 'no user hooks' (got $WARN_COUNT; stderr: '$ERR')"
fi
chmod 600 "$CASE_DIR/locked-settings.json"

extraCase settings-readable-no-warning none
printf '{"hooks":{"PreToolUse":%s}}\n' "$PRE_HOOK" >"$CASE_DIR/settings.json"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20 CLAUDE_SETTINGS_FILE="$CASE_DIR/settings.json"
expectResult "a readable user settings file" 0 green ""
! printf '%s\n' "$ERR" | grep -q 'no user hooks' ||
  failCase "readable settings: stderr must not warn 'no user hooks' (stderr: '$ERR')"

# 20.5, 20.6 A policy missing any of tests, specs and lock fails closed before
# the run (expectPolicyUnreadable asserts claude never starts).
newCase policy-partial-setup
PARTIAL_DIR="$CASE_DIR"
writePolicy "$PARTIAL_DIR/tests-only.json" "$(jq -n --arg t "$FULL_TESTS" '{patterns: {tests: $t}}')"
expectPolicyUnreadable partial-tests-only "$PARTIAL_DIR/tests-only.json"
writePolicy "$PARTIAL_DIR/no-lock.json" "$(jq -n --arg t "$FULL_TESTS" --arg s "$FULL_SPECS" '{patterns: {tests: $t, specs: $s}}')"
expectPolicyUnreadable partial-without-lock "$PARTIAL_DIR/no-lock.json"
writePolicy "$PARTIAL_DIR/no-tests.json" "$(jq -n --arg s "$FULL_SPECS" --arg l "$FULL_LOCK" '{patterns: {specs: $s, lock: $l}}')"
expectPolicyUnreadable partial-without-tests "$PARTIAL_DIR/no-tests.json"
writePolicy "$PARTIAL_DIR/empty-lock.json" "$(jq -n --arg t "$FULL_TESTS" --arg s "$FULL_SPECS" '{patterns: {tests: $t, specs: $s, lock: ""}}')"
expectPolicyUnreadable partial-empty-lock "$PARTIAL_DIR/empty-lock.json"

# A complete policy still runs and reports green.
newCase policy-complete
writePolicy "$CASE_DIR/complete.json" "$(jq -n --arg t "$FULL_TESTS" --arg s "$FULL_SPECS" --arg l "$FULL_LOCK" '{patterns: {tests: $t, specs: $s, lock: $l}}')"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20 CLAUDE_ROLE_POLICY_FILE="$CASE_DIR/complete.json"
expectResult "a complete role policy" 0 green ""

# 20.7 Errors in the protected-path check fail closed.
# An invalid extended regex in the policy.
extraCase check-bad-regex none
writePolicy "$CASE_DIR/bad-regex.json" "$(jq -n --arg s "$FULL_SPECS" --arg l "$FULL_LOCK" '{patterns: {tests: "([", specs: $s, lock: $l}}')"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20 CLAUDE_ROLE_POLICY_FILE="$CASE_DIR/bad-regex.json"
expectResult "a policy pattern that is an invalid regex" 1 failed protected-path-check-failed

# The changed-path listing fails: the run leaves .git as a gitfile pointing nowhere.
extraCase check-listing-fails break-git
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20
expectResult "a changed-path listing that fails" 1 failed protected-path-check-failed

rm -f "$WORK/claude-extra"
export PATH="$PATH_BEFORE_SETTINGS"

# --- 21. LOW review findings (IAN-712). ---
# 21.1 The user settings path honors CLAUDE_HOME. Order: CLAUDE_SETTINGS_FILE,
# then $CLAUDE_HOME/settings.json, then $HOME/.claude/settings.json. Each file
# holds a PreToolUse hook with a different command, so the hook claude receives
# shows which file was read. The settings wrapper stub (case 19) copies the
# --settings file while claude runs.
export PATH="$SETTINGS_STUBS:$PATH_BEFORE_SETTINGS"
CH_PRE='[{"matcher":"Bash","hooks":[{"type":"command","command":"/guards/claude-home-pre.sh"}]}]'
HOME_PRE='[{"matcher":"Bash","hooks":[{"type":"command","command":"/guards/home-pre.sh"}]}]'
EXPLICIT_PRE='[{"matcher":"Bash","hooks":[{"type":"command","command":"/guards/explicit-pre.sh"}]}]'
# settingsHomeCase <name>: a fresh case with $CASE_DIR/chome/settings.json,
# $CASE_DIR/home/.claude/settings.json and $CASE_DIR/explicit-settings.json.
settingsHomeCase() {
  newCase "$1"
  rm -f "$WORK/claude-settings"
  mkdir -p "$CASE_DIR/chome" "$CASE_DIR/home/.claude"
  printf '{"hooks":{"PreToolUse":%s}}\n' "$CH_PRE" >"$CASE_DIR/chome/settings.json"
  printf '{"hooks":{"PreToolUse":%s}}\n' "$HOME_PRE" >"$CASE_DIR/home/.claude/settings.json"
  printf '{"hooks":{"PreToolUse":%s}}\n' "$EXPLICIT_PRE" >"$CASE_DIR/explicit-settings.json"
}
# expectPassedPreHook <what> <hook json>: the run was green and claude received
# --settings whose PreToolUse equals the hook json.
expectPassedPreHook() {
  local got
  expectResult "$1" 0 green ""
  grep -qx -- "--settings" "$WORK/claude-args" ||
    failCase "$1: --settings must be passed (args: $(tr '\n' ' ' <"$WORK/claude-args"); stderr: '$ERR')"
  [ -f "$WORK/claude-settings" ] || failCase "$1: the --settings file must exist while claude runs"
  got=$(jq -c '.hooks.PreToolUse' "$WORK/claude-settings" 2>/dev/null || true)
  [ "$got" = "$(printf '%s' "$2" | jq -c .)" ] ||
    failCase "$1: the PreToolUse hook passed must be $(printf '%s' "$2" | jq -c .) (got $got)"
}

settingsHomeCase settings-claude-home
dispatchBounded 30 -u CLAUDE_SETTINGS_FILE QWEN_DISPATCH_TIMEOUT_SECONDS=20 \
  CLAUDE_HOME="$CASE_DIR/chome" HOME="$CASE_DIR/home"
expectPassedPreHook "CLAUDE_SETTINGS_FILE unset, CLAUDE_HOME set: \$CLAUDE_HOME/settings.json ahead of \$HOME/.claude" "$CH_PRE"

settingsHomeCase settings-explicit-over-claude-home
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20 CLAUDE_SETTINGS_FILE="$CASE_DIR/explicit-settings.json" \
  CLAUDE_HOME="$CASE_DIR/chome" HOME="$CASE_DIR/home"
expectPassedPreHook "CLAUDE_SETTINGS_FILE wins over CLAUDE_HOME" "$EXPLICIT_PRE"

settingsHomeCase settings-home-fallback
dispatchBounded 30 -u CLAUDE_SETTINGS_FILE -u CLAUDE_HOME QWEN_DISPATCH_TIMEOUT_SECONDS=20 HOME="$CASE_DIR/home"
expectPassedPreHook "CLAUDE_SETTINGS_FILE and CLAUDE_HOME unset: \$HOME/.claude/settings.json" "$HOME_PRE"

settingsHomeCase settings-claude-home-no-home
dispatchBounded 30 -u CLAUDE_SETTINGS_FILE -u HOME QWEN_DISPATCH_TIMEOUT_SECONDS=20 CLAUDE_HOME="$CASE_DIR/chome"
expectPassedPreHook "HOME unset, CLAUDE_HOME set: \$CLAUDE_HOME/settings.json" "$CH_PRE"
! printf '%s\n' "$ERR" | grep -q 'no user hooks' ||
  failCase "HOME unset, CLAUDE_HOME set: stderr must not warn 'no user hooks' (stderr: '$ERR')"
! printf '%s\n' "$ERR" | grep -qF '/.claude/' ||
  failCase "HOME unset, CLAUDE_HOME set: stderr must not name a /.claude/ path (stderr: '$ERR')"
export PATH="$PATH_BEFORE_SETTINGS"

# 21.2 A machine file path that looks like a jq option is still the path. The
# script runs from a directory holding a valid machine file literally named -n.
newCase dash-machine-file
mkdir -p "$CASE_DIR/dashdir"
printf '%s\n' '{"primary": {"agent": "claude"}, "secondary": {"agent": "qwen", "model": "qwen-coder-local", "endpoint": "http://127.0.0.1:11434"}}' \
  >"$CASE_DIR/dashdir/-n"
jq -e . -- "$CASE_DIR/dashdir/-n" >/dev/null || failCase "setup: the -n machine file JSON is malformed"
RETURN_DIR=$(pwd)
cd "$CASE_DIR/dashdir"
dispatchBounded 30 QWEN_DISPATCH_TIMEOUT_SECONDS=20 AGENT_TIER_ASSIGNMENTS_FILE=-n
cd "$RETURN_DIR"
expectResult "AGENT_TIER_ASSIGNMENTS_FILE=-n naming a valid machine file in the working directory" 0 green ""

# 22. The run leaves a readable transcript next to the log; the verdict lines
# are unchanged and the transcript path is the last stdout line.
newCase transcript
printf 'stream-fix\n' >"$WORK/claude-mode"
dispatchCase
expectResult "a run that leaves a transcript" 0 green ""
TR="$LOG.md"
[ -f "$TR" ] || failCase "transcript: $TR must exist"
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "transcript: $TR" ] ||
  failCase "transcript: the last stdout line must name $TR (stdout: '$OUT')"
grep -q 'HELLO-FROM-QWEN' "$TR" || failCase "transcript: must hold Qwen's message"
grep -q '\*\*Bash\*\*: `ls src`' "$TR" || failCase "transcript: must hold one line per tool call"
grep -q 'FINAL-WORDS' "$TR" || failCase "transcript: must hold the final result"
grep -q '^    8$' "$TR" && grep -q 'more lines\]' "$TR" && ! grep -q '^    9$' "$TR" ||
  failCase "transcript: a tool result must be cut to 8 lines ($(cat "$TR"))"
! grep -q '"subtype":"token"' "$TR" || failCase "transcript: system events must be dropped"

# 23. A transcript that cannot be written never changes the verdict: a directory
# sits where <log>.md would go, so the run stays green with exit 0, the verdict
# lines are unchanged, and no transcript line is printed.
newCase transcript-unwritable
printf 'stream-fix\n' >"$WORK/claude-mode"
mkdir -p "$LOG.md"
dispatchCase
expectResult "a run whose transcript cannot be written" 0 green ""
[ -d "$LOG.md" ] || failCase "transcript-unwritable: $LOG.md must still be the directory"
! printf '%s\n' "$OUT" | grep -q '^transcript:' ||
  failCase "transcript-unwritable: no transcript line may be printed (stdout: '$OUT')"

echo "PASS: qwen-implementer-dispatch"
