#!/usr/bin/env bash
# audit-log-append.sh: sourced helper, not a hook. Appends one line to the
# tool-call audit log (spec docs/specs/2026-10-05-audit-log.md): a `tool` line
# from hooks/audit-log.sh after every completed tool call, and a `decision`
# line from each guard at the point it emits deny or ask.
#
# Directory ${AGENT_AUDIT_DIR:-$HOME/.local/state/agent-audit}, one file per
# UTC day (YYYY-MM-DD.jsonl), file 0600, directory 0700. One JSON object per
# line, keys in order: ts, session, event, tool, repo, cwd, input, and for a
# decision line hook, rule, decision.
#
# The input summary is the Bash command, the Read/Write/Edit/NotebookEdit
# path, the Grep/Glob pattern and path, the Agent/Task description, and for
# any other tool (MCP included) the argument names only, never their values.
# It is redacted before it is capped at 2000 characters, so a cap can never
# leave half a secret behind: enforce/secret-patterns.txt; the value, quoted or
# not, after password, passwd, secret, token or api_key/api-key (any case, so
# access_token and auth_token too, the key optionally quoted) and `=` or `:`;
# mysql's glued -p<value>; the value of a header whose name contains key,
# token, secret, auth or cookie; a Bearer token; URL userinfo. Every other
# string field is redacted too. When secret-patterns.txt is missing or a
# pattern in it does not compile, the remaining rules still apply and the line
# gains "redaction":"degraded"; a healthy line has no redaction key.
#
# A line is one write of at most 4000 bytes, under PIPE_BUF (4096), to a file
# opened for append, so concurrent sessions never interleave a line. The first
# write of a UTC day removes *.jsonl files in the directory older than 30 days.
#
# Never fails, prints, or blocks the caller: the write runs in a subshell with
# its output discarded, so a missing jq, an unwritable directory, a malformed
# payload, or an unset variable under the caller's set -u ends the subshell,
# never the guard. Every name here carries the audit_log_ or AUDIT_LOG_ prefix
# so sourcing it into a guard cannot shadow the guard's own functions.

AUDIT_LOG_HELPER_DIR="${BASH_SOURCE[0]%/*}"
[ "$AUDIT_LOG_HELPER_DIR" != "${BASH_SOURCE[0]}" ] || AUDIT_LOG_HELPER_DIR="."

# audit_log_jq_program: the jq filter that turns a hook payload into the
# UTC day on the first output line and the finished log line on the second.
# shellcheck disable=SC2016  # jq variables, not shell ones
AUDIT_LOG_JQ_PROGRAM='
def compiles: . as $p | try ("" | test($p) | true) catch false;
($pattern_lines | split("\n") | map(select(. != ""))) as $all
| ($all | map(select(compiles)) | join("|")) as $joined
| (if $joined | compiles then $joined else "" end) as $patterns
| ($patterns_missing == "1" or ($all | map(select(compiles)) | length) < ($all | length) or $patterns != $joined) as $degraded
| def shrink($n): if length > $n then .[0:([$n - 3, 0] | max)] + "..." else . end;
def qvalue: "(?:\"[^\"]*\"|\\x27[^\\x27]*\\x27|[^\\s&;|\\x27\"]+)";
def secret_header: "[A-Za-z0-9-]*(?i:key|token|secret|auth|cookie)[A-Za-z0-9-]*";
def redact:
  (if $patterns == "" then . else (try gsub($patterns; "***") catch "***") end)
  | gsub("(?<k>(?i:password|passwd|secret|token|api[_-]key)[\"\\x27]?\\s*[:=]\\s*)" + qvalue; "\(.k)***")
  | gsub("(?<k>\\b(?:mysql|mariadb)[A-Za-z_-]*\\s(?:[^;&|\\n]*?\\s)?-p)" + qvalue; "\(.k)***")
  | gsub("(?<k>[\"\\x27]" + secret_header + ":\\s*)[^\"\\x27\\n]+"; "\(.k)***")
  | gsub("(?<k>(?:-H|--header)[=\\s]+" + secret_header + ":\\s*)[^\\s\\x27\"]+"; "\(.k)***")
  | gsub("(?<k>(?i:bearer)\\s+)[^\\s\\x27\"]+"; "\(.k)***")
  | gsub("(?<k>[A-Za-z][A-Za-z0-9+.-]*://)[^/@\\s]+@"; "\(.k)***@");
def text: if . == null then "" elif type == "string" then . else tojson end;
def summary:
  (.tool_name | text) as $t
  | (.tool_input // {}) as $i
  | if ($i | type) != "object" then ""
    elif $t == "Bash" then ($i.command | text)
    elif ($t == "Read" or $t == "Write" or $t == "Edit" or $t == "NotebookEdit") then (($i.file_path // $i.notebook_path) | text)
    elif ($t == "Grep" or $t == "Glob") then ([$i.pattern, $i.path] | map(select(. != null) | text) | join(" "))
    elif ($t == "Agent" or $t == "Task") then ($i.description | text)
    else ($i | keys_unsorted | join(","))
    end;
if type != "object" then error("payload is not an object") else . end
| now as $now
| {
    ts: ($now | todate),
    session: ((.session_id // "-") | text | if . == "" then "-" else . end | redact),
    event: $event,
    tool: (.tool_name | text | redact),
    repo: ($repo | redact),
    cwd: ($cwd | redact),
    input: (summary | redact)
  }
  + (if $event == "decision" then {
      hook: $hook,
      rule: ([$reason | match("[RB]-[0-9]+").string] | first // "-"),
      decision: $decision
    } else {} end)
  + (if $degraded then {redaction: "degraded"} else {} end)
  | . as $line
  | def fit($i; $f): $line | .input |= shrink($i) | with_entries(if .key == "input" then . else .value |= shrink($f) end) | tojson;
    ($now | strftime("%Y-%m-%d")),
    (first(([2000, 512], [1000, 512], [500, 256], [100, 128], [0, 32])
      | fit(.[0]; .[1]) | select(utf8bytelength <= 3999)) // fit(0; 8))
'

# audit_log_patterns: sets AUDIT_LOG_PATTERNS to the secret-patterns.txt
# patterns, one per line, read without starting a process, and
# AUDIT_LOG_PATTERNS_MISSING to 1 when the file is absent.
audit_log_patterns() {
  local file="$AUDIT_LOG_HELPER_DIR/../enforce/secret-patterns.txt" line
  AUDIT_LOG_PATTERNS=""
  AUDIT_LOG_PATTERNS_MISSING=0
  [ -f "$file" ] || { AUDIT_LOG_PATTERNS_MISSING=1; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    AUDIT_LOG_PATTERNS="${AUDIT_LOG_PATTERNS:+$AUDIT_LOG_PATTERNS$'\n'}$line"
  done < "$file"
}

# audit_log_repo_top <dir>: sets AUDIT_LOG_REPO_TOP to the nearest directory
# at or above <dir> holding a .git entry (a directory, or the file a worktree
# or submodule has), else empty: the git top level, found without starting a
# git process on every tool call.
audit_log_repo_top() {
  local dir="$1"
  AUDIT_LOG_REPO_TOP=""
  case "$dir" in /*) ;; *) return 0 ;; esac
  while [ -n "$dir" ]; do
    if [ -e "$dir/.git" ]; then AUDIT_LOG_REPO_TOP="$dir"; return 0; fi
    dir="${dir%/*}"
  done
  [ -e /.git ] && AUDIT_LOG_REPO_TOP="/"
  return 0
}

# audit_log_write <payload> <event> [hook] [decision] [reason]: builds and
# appends one line. Run only through audit_log_append, in a subshell.
audit_log_write() {
  local payload="$1" event="$2" hook="${3:-}" decision="${4:-}" reason="${5:-}"
  local dir="${AGENT_AUDIT_DIR:-}" cwd repo out day line file first=0
  if [ -z "$dir" ]; then
    [ -n "${HOME:-}" ] || return 0
    dir="$HOME/.local/state/agent-audit"
  fi
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cwd=$(printf '%s' "$payload" | jq -r 'if type == "object" then (.cwd // "") | tostring else error("not an object") end') || return 0
  [ -n "$cwd" ] || cwd="$PWD"
  audit_log_repo_top "$cwd"
  repo="${AUDIT_LOG_REPO_TOP##*/}"
  [ -n "$repo" ] || repo="-"
  audit_log_patterns
  out=$(printf '%s' "$payload" | jq -r \
    --arg event "$event" --arg hook "$hook" --arg decision "$decision" --arg reason "$reason" \
    --arg repo "$repo" --arg cwd "$cwd" \
    --arg pattern_lines "$AUDIT_LOG_PATTERNS" --arg patterns_missing "$AUDIT_LOG_PATTERNS_MISSING" \
    "$AUDIT_LOG_JQ_PROGRAM") || return 0
  day="${out%%$'\n'*}"
  line="${out#*$'\n'}"
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  [ -n "$line" ] && [ "$line" != "$out" ] || return 0
  umask 077
  [ -d "$dir" ] || mkdir -p "$dir" || return 0
  file="$dir/$day.jsonl"
  [ -e "$file" ] || first=1
  printf '%s\n' "$line" >> "$file" || return 0
  if [ "$first" -eq 1 ]; then
    find "$dir" -maxdepth 1 -type f -name '*.jsonl' -mtime +30 -exec rm -f {} +
  fi
  return 0
}

# audit_log_append <payload> <event> [hook] [decision] [reason]: the entry
# point. Never prints, never fails, never ends the caller.
audit_log_append() {
  ( audit_log_write "$@" ) </dev/null >/dev/null 2>&1 || true
}

# audit_log_decision <payload> <hook> <decision> <reason>: a decision line for
# a deny or an ask; any other decision is not logged. The rule is the first
# R-nnn or B-n id in the reason, else `-`; the reason itself is not stored.
audit_log_decision() {
  case "${3:-}" in deny | ask) ;; *) return 0 ;; esac
  audit_log_append "${1:-}" decision "${2:-}" "$3" "${4:-}"
}

# audit_log_hook_output <payload> <hook> <hook output JSON>: a decision line
# read from a PreToolUse decision a guard has already built, for a guard whose
# decision comes from another program (infra-mutation-guard's judge).
audit_log_hook_output() {
  local parsed
  command -v jq >/dev/null 2>&1 || return 0
  parsed=$(printf '%s' "${3:-}" | jq -r '.hookSpecificOutput | (.permissionDecision // "") + "\n" + (.permissionDecisionReason // "")' 2>/dev/null) || return 0
  audit_log_decision "${1:-}" "${2:-}" "${parsed%%$'\n'*}" "${parsed#*$'\n'}"
}
