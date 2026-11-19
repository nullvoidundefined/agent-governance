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
unset QWEN_DISPATCH_TIMEOUT_SECONDS QWEN_DISPATCH_MAX_TURNS AGENT_TIER_ASSIGNMENTS_FILE
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
echo "STUB-CLAUDE-STDOUT-$mode"
echo "STUB-CLAUDE-STDERR-$mode" >&2
fixValue() { printf '#!/usr/bin/env bash\necho 2\n' >src/value.sh; }
case "$mode" in
  fix)
    fixValue
    printf 'helper\n' >src/new_module.sh
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
[ "$(printf '%s\n' "$TAIL" | grep -c .)" -le 60 ] || failCase "tests-failed: at most 60 lines may follow line 2"
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

echo "PASS: qwen-implementer-dispatch"
