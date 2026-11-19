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
#                path), timeout, or process-error.
#   unavailable  exit 3: no-secondary-configured, server-unreachable or
#                model-missing. Claude is never started.
#   usage error  exit 2.
# QWEN_DISPATCH_TIMEOUT_SECONDS (default 1800) and QWEN_DISPATCH_MAX_TURNS
# (default 60) set the caps; the timeout applies to the Claude run and, separately,
# to the final test command. A role policy with no protected-path patterns fails
# closed (failed, policy-unreadable). The script makes no commit, does not move HEAD,
# and leaves Qwen's edits in the working tree for the caller to keep or discard.
#
# Machine file: $AGENT_TIER_ASSIGNMENTS_FILE (default
# ~/.claude/agent-tier-assignments.json), secondary.{agent,model,endpoint}.
# The invocation is the one the slice's spike settled on: normal mode with
# --setting-sources project,local, so the third-party plugins in the user
# settings do not load, plus the user's hooks passed explicitly through
# --settings and the user's CLAUDE.md passed as appended system prompt.
# Claude Code runs with the repo as its working directory and stdin closed, and
# in its own process group so a timeout kills every child it started
# (macOS has no timeout(1) or setsid).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="${CLAUDE_ROLE_POLICY_FILE:-$HERE/role-policy.json}"
USER_SETTINGS="${CLAUDE_SETTINGS_FILE:-${HOME:-}/.claude/settings.json}"
USER_RULES="${HOME:-}/.claude/CLAUDE.md"
MACHINE="${AGENT_TIER_ASSIGNMENTS_FILE:-${HOME:-}/.claude/agent-tier-assignments.json}"
TIMEOUT_SECONDS="${QWEN_DISPATCH_TIMEOUT_SECONDS:-1800}"
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
report() {
  printf '%s\n%s\n' "$1" "$2"
  exit "$3"
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
}

# load_secondary: sets endpoint and model from the machine file, or reports unavailable.
load_secondary() {
  local agent
  [ -f "$MACHINE" ] || report unavailable no-secondary-configured 3
  agent=$(jq -r '.secondary.agent // empty' "$MACHINE" 2>/dev/null) || agent=""
  [ "$agent" = qwen ] || report unavailable no-secondary-configured 3
  model=$(jq -r '.secondary.model // empty' "$MACHINE" 2>/dev/null) || model=""
  endpoint=$(jq -r '.secondary.endpoint // empty' "$MACHINE" 2>/dev/null) || endpoint=""
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

# run_capped <out file> <command...>: runs the command in the repo with stdin closed,
# appending stdout and stderr to the out file, in its own process group, under the
# timeout; sets capStatus to ok, timeout or process-error. On a timeout the whole
# group is killed, so no child outlives the run.
run_capped() {
  local out="$1" pid waited=0
  shift
  : >>"$out"
  set -m
  (
    cd "$repo" || exit 1
    exec "$@" </dev/null >>"$out" 2>&1
  ) &
  pid=$!
  set +m

  # Poll rather than block, so the timeout can fire; tenth-of-a-second ticks.
  while kill -0 "$pid" 2>/dev/null; do
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
  if [ -f "$USER_SETTINGS" ] && jq '{hooks: .hooks}' "$USER_SETTINGS" >"$SCRATCH/hooks.json" 2>/dev/null; then
    args+=(--settings "$SCRATCH/hooks.json")
  fi
  [ ! -f "$USER_RULES" ] || args+=(--append-system-prompt-file "$USER_RULES")

  : >"$log"
  run_capped "$log" env ANTHROPIC_BASE_URL="$endpoint" ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY= \
    claude "${args[@]}"
}

# load_patterns: reads the protected-path patterns (tests, specs, lock) from the role
# policy into $patterns before Qwen runs, so a run cannot rewrite them; empty when the
# policy is missing, malformed or has none of the three.
load_patterns() {
  patterns=$(jq -r '[.patterns.tests, .patterns.specs, .patterns.lock] | map(select(. != null and . != "")) | .[]' "$POLICY" 2>/dev/null) || patterns=""
}

# find_protected_path: prints the first changed path, tracked or untracked, that matches
# one of $patterns.
find_protected_path() {
  local path pat
  while IFS= read -r -d '' path; do
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      if printf '%s\n' "$path" | grep -Eq -- "$pat"; then
        printf '%s' "$path"
        return 0
      fi
    done <<<"$patterns"
  done < <(
    git -C "$repo" -c core.quotepath=off diff --name-only --no-renames -z "$redSha" 2>/dev/null
    git -C "$repo" -c core.quotepath=off ls-files --others --exclude-standard -z 2>/dev/null
  )
  return 1
}

parse_flags "$@"
validate_inputs
load_secondary
check_server

load_patterns
run_claude
case "$capStatus" in
  timeout) report failed timeout 1 ;;
  process-error) report failed process-error 1 ;;
esac
[ -n "$patterns" ] || report failed "policy-unreadable: no protected-path patterns in $POLICY" 1

if protectedPath=$(find_protected_path); then
  report failed "touched-protected-path $protectedPath" 1
fi

run_capped "$SCRATCH/test.out" bash -c "$testCmd"
case "$capStatus" in
  timeout) report failed timeout 1 ;;
  ok) report green "the test command passed and no protected path changed" 0 ;;
esac
printf 'failed\ntests-failed\n'
tail -n 60 "$SCRATCH/test.out"
exit 1
