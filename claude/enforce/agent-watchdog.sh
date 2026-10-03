#!/usr/bin/env bash
# agent-watchdog.sh: watches one background subagent's transcript for R-708
# and exits when the main session should look at it (IAN-605).
#
#   agent-watchdog.sh <output file> [--stall-seconds N] [--limit-seconds N]
#                     [--poll-seconds N]
#
# The main session starts it as a background Bash command right after a
# background Agent launch, with the `output_file` path the launch printed.
# Claude Code re-invokes the main session when a background command exits, so
# this script's exit is the wake-up; it never stops the agent itself, because
# nothing outside the model can (only TaskStop can). It exits:
#   0  "finished": the transcript's last entry is an assistant turn that ended
#      (stop_reason end_turn, no tool call pending); nothing to do.
#   3  "stalled": the transcript has not grown for the stall time (default
#      600 s, owner decision 2026-10-03; one Bash call can legitimately run 10
#      minutes, so the stall clock starts at the transcript's last growth).
#   4  "time limit": the agent has run for the limit (default 2,700 s, 45
#      minutes, owner decision 2026-10-03), whatever it is doing.
#   2  usage error, or the output file never appeared within the stall time.
# Each exit prints one line naming the reason, the agent's elapsed time and
# its transcript size, so the woken session can decide whether to TaskStop.
# The output file is usually a symlink to the agent's JSONL transcript; size is
# read through it with `wc -c`, which follows the link on every platform.
set -uo pipefail

STALL_SECONDS=600
LIMIT_SECONDS=2700
POLL_SECONDS=15
TAIL_LINES=50
OUTPUT_FILE=""

# usage_error <message>: prints the message and the usage line, exits 2.
usage_error() {
  echo "agent-watchdog: $1" >&2
  echo "usage: agent-watchdog.sh <output file> [--stall-seconds N] [--limit-seconds N] [--poll-seconds N]" >&2
  exit 2
}

# is_whole_number <value>: true for a non-negative integer.
is_whole_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stall-seconds|--limit-seconds|--poll-seconds)
      [ $# -ge 2 ] && is_whole_number "$2" && [ "$2" -gt 0 ] || usage_error "$1 needs a positive whole number"
      case "$1" in
        --stall-seconds) STALL_SECONDS=$2 ;;
        --limit-seconds) LIMIT_SECONDS=$2 ;;
        --poll-seconds) POLL_SECONDS=$2 ;;
      esac
      shift 2 ;;
    -*) usage_error "unknown option $1" ;;
    *) [ -z "$OUTPUT_FILE" ] || usage_error "only one output file"; OUTPUT_FILE=$1; shift ;;
  esac
done
[ -n "$OUTPUT_FILE" ] || usage_error "no output file"

# transcript_size: prints the transcript's byte size, or nothing while absent.
transcript_size() {
  [ -e "$OUTPUT_FILE" ] || return 0
  wc -c < "$OUTPUT_FILE" 2>/dev/null | tr -d ' '
}

# last_turn_entry: prints, as one compact JSON object, the transcript's last
# conversation entry (assistant or user) among its final lines. Trailing
# entries of other types, such as an attachment written after the final turn,
# are skipped (R-517 r1 on PR #184); a line that is not JSON is ignored.
last_turn_entry() {
  [ -e "$OUTPUT_FILE" ] || return 0
  tail -n "$TAIL_LINES" "$OUTPUT_FILE" 2>/dev/null \
    | jq -c 'select(type == "object" and (.type == "assistant" or .type == "user"))' 2>/dev/null \
    | tail -n 1
}

# has_finished: true when the last conversation entry is an assistant turn
# that ended with no tool call pending.
has_finished() {
  last_turn_entry | jq -e '
    .type == "assistant"
    and .message.stop_reason == "end_turn"
    and ([.message.content[]? | select(.type == "tool_use")] | length == 0)
  ' >/dev/null 2>&1
}

# describe_last_entry: prints a short, content-free summary of the last
# conversation entry (its type, stop reason, and the name of any pending tool
# call), so the woken session can judge progress without reading the
# transcript, which can be too large for its context.
describe_last_entry() {
  local summary
  summary=$(last_turn_entry | jq -r '
    "last entry: " + (.type // "?")
    + (if .message.stop_reason then ", stop " + .message.stop_reason else "" end)
    + ([.message.content[]? | select(.type == "tool_use") | .name] as $tools
       | if ($tools | length) > 0 then ", pending tool " + ($tools | join(",")) else "" end)
  ' 2>/dev/null)
  printf '%s' "${summary:-last entry: none}"
}

# report <reason> <exit code>: prints the wake line and exits with the code.
report() {
  local now; now=$(date +%s)
  echo "agent-watchdog: $1 after $((now - STARTED_AT))s; transcript $(transcript_size || true) bytes; $(describe_last_entry); $OUTPUT_FILE"
  exit "$2"
}

STARTED_AT=$(date +%s)
LAST_SIZE=""
LAST_GROWTH_AT=$STARTED_AT
while :; do
  has_finished && report "finished" 0
  NOW=$(date +%s)
  SIZE=$(transcript_size)
  if [ -n "$SIZE" ] && [ "$SIZE" != "$LAST_SIZE" ]; then
    LAST_SIZE=$SIZE
    LAST_GROWTH_AT=$NOW
  fi
  if [ $((NOW - STARTED_AT)) -ge "$LIMIT_SECONDS" ]; then
    report "time limit (${LIMIT_SECONDS}s) reached" 4
  fi
  if [ $((NOW - LAST_GROWTH_AT)) -ge "$STALL_SECONDS" ]; then
    [ -n "$LAST_SIZE" ] || report "output file never appeared" 2
    report "stalled: no transcript growth for ${STALL_SECONDS}s" 3
  fi
  sleep "$POLL_SECONDS"
done
