#!/usr/bin/env bash
# claude-hook-adapter.sh
#
# Runs the Claude Code hooks under Cursor. Cursor's hook protocol and Claude
# Code's differ in event names, payload shape, and response shape, but the
# gates themselves (secret scan, em-dash block, destructive-command guards,
# push-time linters, the turn-end verification gate) are plain scripts that
# read JSON on stdin and write JSON on stdout. This adapter is the only
# Cursor-specific code: it translates one Cursor event into the Claude Code
# payload the hooks expect, runs each hook named on its command line, and
# translates the decisions back into the response Cursor understands. The
# hook scripts in ~/.claude/hooks/ stay untouched, so a fix there reaches
# both tools.
#
# Usage (from ~/.cursor/hooks.json; this file is copied there by cursor/build.mjs):
#   claude-hook-adapter.sh <cursorEvent> <hook-name> [<hook-name> ...]
# where <hook-name> is a basename in ~/.claude/hooks/ without ".sh".
#
# Event map (Cursor -> Claude Code):
#   beforeShellExecution -> PreToolUse Bash        {permission, user_message, agent_message}
#   afterShellExecution  -> PostToolUse Bash       {additional_context} (deferred to stop as well)
#   beforeMCPExecution   -> PreToolUse mcp__*      {permission, user_message, agent_message}
#   afterFileEdit        -> PreToolUse+PostToolUse Write|Edit, replayed after the fact;
#                           findings are deferred and surfaced by the stop hook
#   beforeReadFile       -> the Read(...) deny rules of ~/.claude/settings.json
#   preToolUse           -> PreToolUse Write|Edit, only when the payload describes a
#                           file write (newer Cursor builds; lets the edit gates deny
#                           before the edit lands instead of deferring)
#   sessionStart         -> SessionStart           {additional_context}
#   sessionEnd           -> SessionEnd             (no response)
#   stop                 -> Stop                   {followup_message}
#
# Cursor has no hook that runs BEFORE a file edit lands, so the edit gates
# cannot deny. They run after the edit instead and their would-be denials are
# written to a per-conversation findings file; the stop hook turns that file
# into a followup_message, which Cursor submits as the next user turn, so the
# agent is told to repair the violation before the turn is accepted as done.
#
# Fail open: an adapter fault must never lock the user out of their editor.
# Every path that cannot decide answers allow (or an empty object).
#
# Debug: CLAUDE_CURSOR_HOOK_DEBUG=1 appends every raw payload and every hook's
# stdout to $CLAUDE_CURSOR_STATE_DIR/debug.log (default
# ~/.claude/.cursor-hook-state/debug.log). Use it the first time a Cursor
# release changes a payload field.
#
# Manual test:
#   printf '{"command":"ls -la","cwd":"/tmp","workspace_roots":["/tmp"]}' \
#     | ~/.cursor/hooks/claude-hook-adapter.sh beforeShellExecution secret-scan no-em-dash
# Should print {"permission":"allow"}.

set -uo pipefail

EVENT="${1:-}"
shift || true
HOOK_NAMES=("$@")

# The Claude Code configuration this port was generated from. Overridable so
# the fixture tests can run against a checkout that is not at ~/.claude.
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_HOOKS_DIR="${CLAUDE_HOOKS_DIR:-$CLAUDE_HOME/hooks}"
STATE_DIR="${CLAUDE_CURSOR_STATE_DIR:-$CLAUDE_HOME/.cursor-hook-state}"
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$CLAUDE_HOME/settings.json}"

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || INPUT='{}'
printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1 || INPUT='{}'

CONVERSATION_ID=$(printf '%s' "$INPUT" | jq -r '.conversation_id // "default"')
ROOT=$(printf '%s' "$INPUT" | jq -r '.cwd // (.workspace_roots[0] // "")')
[ -n "$ROOT" ] || ROOT="$PWD"
[ -d "$ROOT" ] && cd "$ROOT" 2>/dev/null

SAFE_ID=$(printf '%s' "$CONVERSATION_ID" | tr -c 'A-Za-z0-9_.-' '_')
FINDINGS_FILE="$STATE_DIR/$SAFE_ID.findings"
LAST_FOLLOWUP_FILE="$STATE_DIR/$SAFE_ID.last-followup"

debug() {
  [ -n "${CLAUDE_CURSOR_HOOK_DEBUG:-}" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >>"$STATE_DIR/debug.log" 2>/dev/null || true
}
debug "in:$EVENT" "$INPUT"

# --- running one Claude Code hook --------------------------------------------

HOOK_OUT=""
HOOK_ERR=""
HOOK_STATUS=0

run_hook() {
  local name="$1" payload="$2" script err_file
  script="$CLAUDE_HOOKS_DIR/$name.sh"
  HOOK_OUT=""
  HOOK_ERR=""
  HOOK_STATUS=0
  if [ ! -x "$script" ]; then
    debug "missing" "$script"
    return 0
  fi
  err_file=$(mktemp)
  HOOK_OUT=$(printf '%s' "$payload" | "$script" 2>"$err_file")
  HOOK_STATUS=$?
  HOOK_ERR=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  debug "out:$name:$HOOK_STATUS" "$HOOK_OUT"
  [ -n "$HOOK_ERR" ] && debug "err:$name" "$HOOK_ERR"
  return 0
}

json_field() {
  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true
}

# Decision state accumulated across the hooks of one event.
WORST="allow"
REASONS=""
CONTEXT=""

rank() {
  case "$1" in deny) echo 3 ;; ask) echo 2 ;; *) echo 1 ;; esac
}

append_text() {
  # $1 = current buffer, $2 = addition; joined by a blank line.
  if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s\n\n%s' "$1" "$2"; fi
}

absorb_decision() {
  # Reads HOOK_OUT / HOOK_ERR / HOOK_STATUS into WORST, REASONS, CONTEXT.
  local decision reason ctx
  decision=$(json_field "$HOOK_OUT" '.hookSpecificOutput.permissionDecision')
  reason=$(json_field "$HOOK_OUT" '.hookSpecificOutput.permissionDecisionReason')
  if [ -z "$decision" ] && [ "$(json_field "$HOOK_OUT" '.decision')" = "block" ]; then
    decision="deny"
    reason=$(json_field "$HOOK_OUT" '.reason')
  fi
  # Claude Code treats exit 2 as a block whose reason is stderr.
  if [ -z "$decision" ] && [ "$HOOK_STATUS" -eq 2 ]; then
    decision="deny"
    reason="$HOOK_ERR"
  fi
  case "$decision" in
    deny | ask)
      if [ "$(rank "$decision")" -gt "$(rank "$WORST")" ]; then WORST="$decision"; fi
      [ -n "$reason" ] && REASONS=$(append_text "$REASONS" "$reason")
      ;;
  esac
  ctx=$(json_field "$HOOK_OUT" '.hookSpecificOutput.additionalContext')
  [ -n "$ctx" ] && CONTEXT=$(append_text "$CONTEXT" "$ctx")
  ctx=$(json_field "$HOOK_OUT" '.systemMessage')
  [ -n "$ctx" ] && CONTEXT=$(append_text "$CONTEXT" "$ctx")
  return 0
}

run_all() {
  # $1 = payload; runs every hook named on the command line against it.
  local name
  for name in "${HOOK_NAMES[@]+"${HOOK_NAMES[@]}"}"; do
    run_hook "$name" "$1"
    absorb_decision
  done
}

emit_permission() {
  if [ "$WORST" = "allow" ]; then
    if [ -n "$CONTEXT" ]; then
      jq -n --arg m "$CONTEXT" '{permission:"allow", agent_message:$m}'
    else
      printf '{"permission":"allow"}\n'
    fi
    return 0
  fi
  local message="$REASONS"
  [ -n "$CONTEXT" ] && message=$(append_text "$message" "$CONTEXT")
  jq -n --arg p "$WORST" --arg m "$message" '{permission:$p, user_message:$m, agent_message:$m}'
}

# --- deferred findings (edit gates and post-shell warnings) ----------------

record_finding() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n\n' "$1" >>"$FINDINGS_FILE" 2>/dev/null || true
}

# --- the Bash(...) and Read(...) rules of settings.json -------------------------
# shellcheck source=../../enforce/settingsPermissionRules.sh
source "$CLAUDE_HOME/enforce/settingsPermissionRules.sh" 2>/dev/null || true

apply_bash_permission_rules() {
  local cmd="$1" rule
  type matching_bash_rule >/dev/null 2>&1 || return 0
  if rule=$(matching_bash_rule deny "$cmd"); then
    WORST="deny"
    REASONS=$(append_text "$REASONS" "settings.json denies \`Bash($rule)\` (Claude Code permissions.deny, mirrored under Cursor). A human runs this manually if it is genuinely required.")
  elif rule=$(matching_bash_rule ask "$cmd"); then
    WORST="ask"
    REASONS=$(append_text "$REASONS" "settings.json asks before \`Bash($rule)\` (Claude Code permissions.ask, mirrored under Cursor). Confirm with the user before running it.")
  fi
}

# --- events -------------------------------------------------------------------

handle_before_shell() {
  local cmd payload
  cmd=$(printf '%s' "$INPUT" | jq -r '.command // ""')
  [ -n "$cmd" ] || { printf '{"permission":"allow"}\n'; return 0; }
  apply_bash_permission_rules "$cmd"
  payload=$(jq -n --arg c "$cmd" --arg cwd "$ROOT" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')
  run_all "$payload"
  emit_permission
}

handle_after_shell() {
  local cmd output payload
  cmd=$(printf '%s' "$INPUT" | jq -r '.command // ""')
  output=$(printf '%s' "$INPUT" | jq -r '.output // ""')
  payload=$(jq -n --arg c "$cmd" --arg o "$output" --arg cwd "$ROOT" \
    '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:$c}, tool_response:$o, cwd:$cwd}')
  run_all "$payload"
  if [ -n "$CONTEXT" ]; then
    # Cursor currently ignores afterShellExecution output, so the warning is
    # also deferred to the stop hook, where a followup_message does reach the
    # agent. Emitting it here costs nothing and works if a later Cursor honors it.
    record_finding "$CONTEXT"
    jq -n --arg m "$CONTEXT" '{additional_context:$m}'
  else
    printf '{}\n'
  fi
}

handle_before_mcp() {
  local tool payload
  tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
  [ -n "$tool" ] || { printf '{"permission":"allow"}\n'; return 0; }
  # The Claude Code guards match on the mcp__<server>__<tool> naming; Cursor
  # reports the bare tool name, so it is given a synthetic server segment.
  case "$tool" in mcp__*) ;; *) tool="mcp__cursor__$tool" ;; esac
  payload=$(printf '%s' "$INPUT" | jq --arg t "$tool" --arg cwd "$ROOT" \
    '{hook_event_name:"PreToolUse", tool_name:$t, tool_input:(.tool_input // .arguments // {}), cwd:$cwd}')
  run_all "$payload"
  emit_permission
}

handle_after_file_edit() {
  local file count index old new payload findings
  file=$(printf '%s' "$INPUT" | jq -r '.file_path // ""')
  [ -n "$file" ] || return 0
  count=$(printf '%s' "$INPUT" | jq -r '.edits | length' 2>/dev/null || echo 0)
  [ "$count" -gt 0 ] || count=1
  index=0
  while [ "$index" -lt "$count" ]; do
    old=$(printf '%s' "$INPUT" | jq -r ".edits[$index].old_string // \"\"" 2>/dev/null || true)
    new=$(printf '%s' "$INPUT" | jq -r ".edits[$index].new_string // \"\"" 2>/dev/null || true)
    if [ -z "$old" ]; then
      payload=$(jq -n --arg f "$file" --arg c "$new" --arg cwd "$ROOT" \
        '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:$f, content:$c}, cwd:$cwd}')
    else
      payload=$(jq -n --arg f "$file" --arg o "$old" --arg n "$new" --arg cwd "$ROOT" \
        '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$f, old_string:$o, new_string:$n}, cwd:$cwd}')
    fi
    WORST="allow"; REASONS=""; CONTEXT=""
    run_all "$payload"
    findings=""
    if [ "$WORST" != "allow" ]; then
      findings="A Claude Code gate would have DENIED this edit to $file (Cursor cannot block an edit before it lands, so repair it now):"$'\n'"$REASONS"
    fi
    [ -n "$CONTEXT" ] && findings=$(append_text "$findings" "$CONTEXT")
    if [ -n "$findings" ]; then
      record_finding "$findings"
      printf '%s\n' "$findings" >&2
    fi
    index=$((index + 1))
  done
  return 0
}

# preToolUse arrived after Cursor 1.7 and its payload is not pinned down in
# any source this adapter was written from, so the handler is defensive: it
# acts only when tool_input carries a recognizable file path plus new content,
# and answers allow for anything else. Shell commands are left to
# beforeShellExecution so no gate runs twice.
handle_pre_tool_use() {
  local file content old_string payload
  file=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.file_path // .path // .target_file // .relative_workspace_path // .filePath // "")' 2>/dev/null || true)
  content=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.content // .contents // .code_edit // .new_string // .new_str // "")' 2>/dev/null || true)
  old_string=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.old_string // .old_str // "")' 2>/dev/null || true)
  if [ -z "$file" ] || [ -z "$content" ] || printf '%s' "$INPUT" | jq -e '.tool_input.command' >/dev/null 2>&1; then
    printf '{"permission":"allow"}\n'
    return 0
  fi
  case "$file" in /*) ;; *) file="$ROOT/$file" ;; esac
  if [ -n "$old_string" ]; then
    payload=$(jq -n --arg f "$file" --arg o "$old_string" --arg n "$content" --arg cwd "$ROOT" \
      '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$f, old_string:$o, new_string:$n}, cwd:$cwd}')
  else
    payload=$(jq -n --arg f "$file" --arg c "$content" --arg cwd "$ROOT" \
      '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:$f, content:$c}, cwd:$cwd}')
  fi
  run_all "$payload"
  emit_permission
}

handle_before_read() {
  local file
  file=$(printf '%s' "$INPUT" | jq -r '.file_path // ""')
  if [ -n "$file" ] && type read_is_denied >/dev/null 2>&1 && read_is_denied "$file"; then
    jq -n --arg f "$file" '{permission:"deny",
      user_message:("Read of " + $f + " blocked (R-102): credential files stay off-path. Use the value from memory or ask the user; never echo it."),
      agent_message:("Read of " + $f + " blocked (R-102): credential files stay off-path. Use the value from memory or ask the user; never echo it.")}'
    return 0
  fi
  printf '{"permission":"allow"}\n'
}

handle_session_start() {
  local payload
  rm -f "$FINDINGS_FILE" "$LAST_FOLLOWUP_FILE" 2>/dev/null || true
  payload=$(jq -n --arg cwd "$ROOT" '{hook_event_name:"SessionStart", source:"startup", cwd:$cwd}')
  run_all "$payload"
  if [ -n "$CONTEXT" ]; then
    jq -n --arg m "$CONTEXT" '{additional_context:$m}'
  else
    printf '{}\n'
  fi
}

handle_session_end() {
  local payload
  payload=$(jq -n --arg cwd "$ROOT" '{hook_event_name:"SessionEnd", reason:"other", cwd:$cwd}')
  run_all "$payload"
  rm -f "$FINDINGS_FILE" "$LAST_FOLLOWUP_FILE" 2>/dev/null || true
  printf '{}\n'
}

handle_stop() {
  local status payload followup deferred digest previous
  status=$(printf '%s' "$INPUT" | jq -r '.status // "completed"')
  # An aborted or errored turn is not a finished turn; nothing to verify.
  [ "$status" = "completed" ] || { printf '{}\n'; return 0; }
  payload=$(jq -n --arg cwd "$ROOT" '{hook_event_name:"Stop", stop_hook_active:false, cwd:$cwd}')
  run_all "$payload"
  followup=""
  if [ -f "$FINDINGS_FILE" ] && [ -s "$FINDINGS_FILE" ]; then
    deferred=$(cat "$FINDINGS_FILE")
    followup="Deferred hook findings from this turn (the Claude Code gates ran after each edit; under Cursor they cannot block, so act on them now):"$'\n\n'"$deferred"
  fi
  rm -f "$FINDINGS_FILE" 2>/dev/null || true
  [ -n "$REASONS" ] && followup=$(append_text "$followup" "$REASONS")
  [ -n "$followup" ] || { printf '{}\n'; return 0; }
  # A followup Cursor submits as the next user turn re-enters this hook when
  # that turn ends. Identical text twice in a row means the agent could not
  # fix it; stop re-submitting rather than loop on a suite that stays red.
  digest=$(printf '%s' "$followup" | shasum -a 256 2>/dev/null | awk '{print $1}')
  previous=$(cat "$LAST_FOLLOWUP_FILE" 2>/dev/null || true)
  if [ -n "$digest" ] && [ "$digest" = "$previous" ]; then
    rm -f "$LAST_FOLLOWUP_FILE" 2>/dev/null || true
    printf '{}\n'
    return 0
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$digest" >"$LAST_FOLLOWUP_FILE" 2>/dev/null || true
  jq -n --arg m "$followup" '{followup_message:$m}'
}

case "$EVENT" in
  beforeShellExecution) handle_before_shell ;;
  afterShellExecution) handle_after_shell ;;
  beforeMCPExecution) handle_before_mcp ;;
  afterFileEdit) handle_after_file_edit ;;
  beforeReadFile) handle_before_read ;;
  preToolUse) handle_pre_tool_use ;;
  sessionStart) handle_session_start ;;
  sessionEnd) handle_session_end ;;
  stop) handle_stop ;;
  *)
    debug "unknown-event" "$EVENT"
    printf '{}\n'
    ;;
esac
exit 0
