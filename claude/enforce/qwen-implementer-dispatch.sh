#!/usr/bin/env bash
# qwen-implementer-dispatch.sh: runs ONE GREEN attempt on the local Qwen model
# and judges the result itself, so the caller does not take Qwen's word for it
# (slice 05 PR 2, docs/slices/slice-05-tiered-agents-and-local-qwen-implementer.md).
#
# Usage: qwen-implementer-dispatch.sh --repo <root> --red <sha> --prompt <file>
#          --log <file> --test-cmd <command>
# Line 1 of stdout is the status, line 2 the reason.
#   green        exit 0: the test command passed and no protected path changed.
#   failed       exit 1: tests-failed (the last 60 lines of the test output
#                follow from line 3), touched-protected-path (line 2 names the
#                path), timeout, stalled, process-error, head-moved, or
#                protected-path-check-failed.
#   unavailable  exit 3: no-secondary-configured, server-unreachable,
#                model-missing, or rules-missing. Claude is never started.
#   usage error  exit 2.
# When the Claude run ends (any outcome after it started), a readable Markdown
# transcript of the --log goes to <log>.md and its path is the LAST stdout line,
# "transcript: <path>", after the verdict lines and any test output. Lines 1 and 2
# are unchanged.
# gitignored paths are not scanned for protected changes, and
# the final test command runs with stdin closed. HEAD movement (head-moved) and protected-path
# check failures (protected-path-check-failed) are reported after the Claude run.
# The role policy is checked before claude starts.
#
# QWEN_DISPATCH_TIMEOUT_SECONDS (default 3600) and QWEN_DISPATCH_MAX_TURNS
# (default 60) set the caps; the timeout applies to the Claude run and, separately,
# to the final test command. QWEN_DISPATCH_IDLE_SECONDS (default 600, 0 disables)
# bounds how long the --log file may go without growing while claude runs; when it
# fires the process group is killed and the result is stalled. The idle watchdog
# covers only the Claude run, never the final test command. A role policy with no
# protected-path patterns fails closed (failed, policy-unreadable). The script makes
# no commit, does not move HEAD, and leaves Qwen's edits in the working tree for the
# caller to keep or discard.
#
# Machine file: $AGENT_TIER_ASSIGNMENTS_FILE (default
# ~/.claude/agent-tier-assignments.json), secondary.{agent,model,endpoint}.
# The invocation is normal mode with --setting-sources project,local, so the
# third-party plugins in the user settings do not load; when the user settings
# file is readable, only its PreToolUse and PostToolUse hooks (the safety
# guards and output redaction) are passed through --settings; Stop,
# SubagentStop and SessionStart hooks are left out because they are
# orchestrator-only (they enforce end-of-turn summary formats and session
# checks); and the implementer-only rules file (default
# claude/enforce/qwen-implementer-rules.md, overridable via
# QWEN_IMPLEMENTER_RULES_FILE) is appended as system prompt.
# The user settings file honors CLAUDE_HOME, which also names the directory of
# the settings file. Claude Code runs with the repo as its working directory and
# stdin closed, and in its own process group so a timeout kills every child it
# started (macOS has no timeout(1) or setsid).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="${CLAUDE_ROLE_POLICY_FILE:-$HERE/role-policy.json}"
if [ -n "${CLAUDE_SETTINGS_FILE:-}" ]; then
  USER_SETTINGS="$CLAUDE_SETTINGS_FILE"
elif [ -n "${CLAUDE_HOME:-}" ]; then
  USER_SETTINGS="$CLAUDE_HOME/settings.json"
elif [ -n "${HOME:-}" ]; then
  USER_SETTINGS="$HOME/.claude/settings.json"
else
  USER_SETTINGS=""
fi
IMPLEMENTER_RULES="${QWEN_IMPLEMENTER_RULES_FILE:-$HERE/qwen-implementer-rules.md}"

. "$HERE/resolve-machine-file.sh"
MACHINE=$(resolve_machine_file)
TIMEOUT_SECONDS="${QWEN_DISPATCH_TIMEOUT_SECONDS:-3600}"
MAX_TURNS="${QWEN_DISPATCH_MAX_TURNS:-60}"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# usage_error <message>: prints the message and the usage line to stderr, exit 2.
usage_error() {
  echo "qwen-implementer-dispatch: $1" >&2
  echo "usage: qwen-implementer-dispatch.sh --repo <root> --red <sha> --prompt <file> --log <file> --test-cmd <command>" >&2
  exit 2
}

# report <status> <reason> <exit code>: prints the two-line result and exits.
# Once the Claude run has produced a transcript, its path is the last line.
report() {
  printf '%s\n%s\n' "$1" "$2"
  print_transcript_note
  exit "$3"
}

# print_transcript_note: prints "transcript: <path>" when a transcript was written.
print_transcript_note() {
  [ -z "${transcript:-}" ] || printf 'transcript: %s\n' "$transcript"
}

# write_transcript: converts the raw stream-json --log into <log>.md, a readable
# Markdown transcript: Qwen's messages, its reasoning clipped to 300 characters,
# one line per tool call, and the first 8 lines of each tool result. The per-token
# system events (about 99% of the log) are dropped. Sets $transcript only when the
# file was written; a failure here never changes the verdict.
write_transcript() {
  local out="$log.md"
  {
    printf '# Qwen run: %s\n\nSource: `%s`\n' "$(basename "$log")" "$log"
    jq -Rr '
      def clip($n): if length > $n then .[0:$n] + " [...]" else . end;
      def firstlines($n): split("\n") | (if length > $n then .[0:$n] + ["[... \(length - $n) more lines]"] else . end) | map("    " + .) | join("\n");
      fromjson? | select(type == "object") |
      if .type == "assistant" then
        (.message.content // [])[] |
        if .type == "text" then "\n**Qwen:** " + .text + "\n"
        elif .type == "thinking" then "\n_Thinking:_ " + (.thinking | gsub("\n"; " ") | clip(300)) + "\n"
        elif .type == "tool_use" then
          "- **" + .name + "**: " + (
            if .name == "Bash" then "`" + (.input.command | gsub("\n"; " ") | clip(200)) + "`"
            elif (.input.file_path? // null) != null then "`" + .input.file_path + "`"
            elif (.input.pattern? // null) != null then "`" + .input.pattern + "`"
            else (.input | tostring | clip(200)) end)
        else empty end
      elif .type == "user" then
        (.message.content // []) | arrays | .[] | select(type == "object" and .type == "tool_result") |
        ((if (.content | type) == "array" then (.content | map(.text? // "") | join("\n")) else (.content // "" | tostring) end) as $t |
         (if .is_error then "  - result (error):\n" else "  - result:\n" end) + ($t | firstlines(8)))
      elif .type == "result" then "\n## Finished\n\n" + (.result // "" | tostring)
      else empty end
    ' "$log"
  } >"$out" 2>/dev/null && transcript="$out"
  return 0
}

# parse_flags <args...>: sets repo, red, prompt, log and testCmd, or fails with a usage error.
parse_flags() {
  repo=""; red=""; prompt=""; log=""; testCmd=""
  local have_repo=0 have_red=0 have_prompt=0 have_log=0 have_test=0
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage_error "$1 needs a value"
    case "$1" in
      --repo) repo="$2"; have_repo=1 ;;
      --red) red="$2"; have_red=1 ;;
      --prompt) prompt="$2"; have_prompt=1 ;;
      --log) log="$2"; have_log=1 ;;
      --test-cmd) testCmd="$2"; have_test=1 ;;
      *) usage_error "unknown argument $1" ;;
    esac
    shift 2
  done
  [ "$have_repo$have_red$have_prompt$have_log$have_test" = "11111" ] ||
    usage_error "--repo, --red, --prompt, --log and --test-cmd are all required"
}

# validate_inputs: checks the repo, the RED sha, the prompt file and the caps.
validate_inputs() {
  [ -d "$repo" ] || usage_error "--repo is not a directory"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || usage_error "--repo is not a git repository"
  case "$red" in -* | "") usage_error "--red must be a commit" ;; esac
  [ "${#red}" -le 100 ] || usage_error "--red is too long"
  redSha=$(git -C "$repo" rev-parse --verify --quiet "$red^{commit}" 2>/dev/null) ||
    usage_error "--red is not a commit in the repository"
  [ -f "$prompt" ] || usage_error "--prompt is not a file"
  [ -n "$testCmd" ] || usage_error "--test-cmd is empty"
  case "$TIMEOUT_SECONDS$MAX_TURNS" in *[!0-9]* | "") usage_error "the caps must be whole numbers" ;; esac
  case "${QWEN_DISPATCH_IDLE_SECONDS:-}" in "" ) ;; *[!0-9]*) usage_error "QWEN_DISPATCH_IDLE_SECONDS must be a whole number" ;; esac
}

# load_secondary: sets endpoint and model from the machine file, or reports unavailable.
load_secondary() {
  local agent
  [ -f "$MACHINE" ] || report unavailable no-secondary-configured 3
  agent=$(jq -r -- '.secondary.agent // empty' "$MACHINE" 2>/dev/null) || agent=""
  [ "$agent" = qwen ] || report unavailable no-secondary-configured 3
  model=$(jq -r -- '.secondary.model // empty' "$MACHINE" 2>/dev/null) || model=""
  endpoint=$(jq -r -- '.secondary.endpoint // empty' "$MACHINE" 2>/dev/null) || endpoint=""
  { [ -n "$model" ] && [ -n "$endpoint" ]; } || report unavailable no-secondary-configured 3
}

# check_server: reports unavailable unless the endpoint answers and lists the model.
check_server() {
  local code
  code=$(curl -sS -m 10 -o "$SCRATCH/tags.json" -w '%{http_code}' "$endpoint/api/tags" 2>/dev/null) ||
    report unavailable server-unreachable 3
  [ "$code" = 200 ] || report unavailable server-unreachable 3
  jq -e --arg m "$model" '[.models[]?.name] | any(. == $m or . == ($m + ":latest"))' "$SCRATCH/tags.json" >/dev/null 2>&1 ||
    report unavailable model-missing 3
}

# run_capped <out file> <idle seconds> <command...>: runs the command in the repo
# with stdin closed, appending stdout and stderr to the out file, in its own
# process group, under the timeout; sets capStatus to ok, timeout, stalled or
# process-error. idle_seconds (default 0, disabled) bounds how long the out file
# may go without growing while the process runs. On a timeout or stall the whole
# group is killed, so no child outlives the run.
run_capped() {
  local out="$1" idle_seconds="${2:-0}" pid waited=0 idle_waited=0
  shift 2
  : >>"$out"
  set -m
  (
    cd "$repo" || exit 1
    exec "$@" </dev/null >>"$out" 2>&1
  ) &
  pid=$!
  set +m
  idle_last_size=0

  # Poll rather than block, so the timeout can fire; tenth-of-a-second ticks.
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$idle_seconds" -gt 0 ] && [ -f "$out" ]; then
      local cur_size
      cur_size=$(wc -c < "$out" | tr -d ' ')
      if [ "$cur_size" = "$idle_last_size" ]; then
        idle_waited=$((idle_waited + 1))
      else
        idle_last_size="$cur_size"
        idle_waited=0
      fi
      if [ "$idle_waited" -ge $((idle_seconds * 10)) ]; then
        kill -TERM -- "-$pid" 2>/dev/null
        sleep 1
        kill -KILL -- "-$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        capStatus=stalled
        return
      fi
    fi
    if [ "$waited" -ge $((TIMEOUT_SECONDS * 10)) ]; then
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      capStatus=timeout
      return
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if wait "$pid"; then capStatus=ok; else capStatus=process-error; fi
}

# run_claude: runs Claude Code against the endpoint under the timeout; sets capStatus.
run_claude() {
  local promptText
  local -a args
  promptText=$(cat "$prompt")
  args=(-p "$promptText" --model "$model" --permission-mode dontAsk
    --allowedTools "Read Edit Write Bash" --max-turns "$MAX_TURNS" --no-session-persistence
    --setting-sources project,local --output-format stream-json --verbose)
  if [ -f "$USER_SETTINGS" ] && jq '{hooks: ((.hooks // {}) | with_entries(select(.key == "PreToolUse" or .key == "PostToolUse")))}' "$USER_SETTINGS" >"$SCRATCH/hooks.json" 2>/dev/null; then
    args+=(--settings "$SCRATCH/hooks.json")
  elif [ ! -f "$USER_SETTINGS" ] || [ ! -r "$USER_SETTINGS" ]; then
    echo "qwen-implementer-dispatch: warning: no user hooks passed to claude" >&2
  fi
  args+=(--append-system-prompt-file "$IMPLEMENTER_RULES")

  : >"$log"
  run_capped "$log" "${QWEN_DISPATCH_IDLE_SECONDS:-600}" env ANTHROPIC_BASE_URL="$endpoint" ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY= \
    claude "${args[@]}"
}

# load_patterns: reads the protected-path patterns (tests, specs, lock) from the role
# policy into $patterns before Qwen runs, so a run cannot rewrite them; empty when the
# policy is missing, malformed or has none of the three. Returns 1 if the policy file
# is missing or unreadable.
load_patterns() {
  [ -f "$POLICY" ] && [ -r "$POLICY" ] || return 1
  local t s l
  t=$(jq -r '.patterns.tests // empty' "$POLICY" 2>/dev/null)
  s=$(jq -r '.patterns.specs // empty' "$POLICY" 2>/dev/null)
  l=$(jq -r '.patterns.lock // empty' "$POLICY" 2>/dev/null)
  if [ -n "$t" ] && [ -n "$s" ] && [ -n "$l" ]; then
    patterns="$t"$'\n'"$s"$'\n'"$l"
  else
    patterns=""
  fi
}

# find_protected_path: prints the first changed path, tracked or untracked, that matches
# one of $patterns. Returns 0 with the path when found, 1 when none changed, 2 on error.
find_protected_path() {
  local pat rc
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    printf '' | grep -Eq -- "$pat" 2>/dev/null
    rc=$?
    [ "$rc" = "0" ] || [ "$rc" = "1" ] || return 2
  done <<<"$patterns"

  local listing="$SCRATCH/protected_listing"
  : >"$listing"
  git -C "$repo" -c core.quotepath=off diff --name-only --no-renames -z "$redSha" >>"$listing" 2>/dev/null
  if [ $? -ne 0 ]; then return 2; fi
  git -C "$repo" -c core.quotepath=off ls-files --others --exclude-standard -z >>"$listing" 2>/dev/null
  if [ $? -ne 0 ]; then return 2; fi

  local path
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      if printf '%s\n' "$path" | grep -Eq -- "$pat"; then
        printf '%s' "$path" | LC_ALL=C tr -d '[:cntrl:]'
        return 0
      fi
    done <<<"$patterns"
  done <"$listing"
  return 1
}

parse_flags "$@"
validate_inputs

# Resolve a relative --log against the caller's working directory, before cd.
if [ -n "$log" ] && [ "${log:0:1}" != "/" ]; then
  log="$PWD/$log"
fi

load_secondary
check_server

[ -f "$IMPLEMENTER_RULES" ] || report unavailable rules-missing 3

# Policy checked before claude starts.
if ! load_patterns; then
  report failed "policy-unreadable: no protected-path patterns in $POLICY" 1
fi
[ -n "$patterns" ] || report failed "policy-unreadable: no protected-path patterns in $POLICY" 1

# Record HEAD before the run so we can detect movement.
headBefore=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || headBefore=""

run_claude
write_transcript
case "$capStatus" in
  timeout) report failed timeout 1 ;;
  stalled) report failed stalled 1 ;;
  process-error) report failed process-error 1 ;;
esac

# Protected-path check first (so commit-test gets touched-protected-path).
protectedPath=$(find_protected_path); ppStatus=$?
case "$ppStatus" in
  0) report failed "touched-protected-path $protectedPath" 1 ;;
  2) report failed protected-path-check-failed 1 ;;
esac

# HEAD movement check after protected-path, before the final test command.
if [ -n "$headBefore" ]; then
  headAfter=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || headAfter=""
  if [ "$headBefore" != "$headAfter" ]; then
    report failed head-moved 1
  fi
fi

run_capped "$SCRATCH/test.out" 0 bash -c "$testCmd"
case "$capStatus" in
  timeout) report failed timeout 1 ;;
  ok) report green "the test command passed and no protected path changed" 0 ;;
esac
printf 'failed\ntests-failed\n'
tail -n 60 "$SCRATCH/test.out"
print_transcript_note
exit 1
