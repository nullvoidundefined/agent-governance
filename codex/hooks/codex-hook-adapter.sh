#!/usr/bin/env bash
# codex-hook-adapter.sh
#
# Runs the Claude Code hooks under OpenAI Codex. Codex's hooks.json uses the
# same schema, events, stdin fields, and stdout fields as Claude Code, so
# nearly every hook could be wired directly. Three things differ, and this
# adapter is where they are handled so the hook scripts stay untouched:
#
#   1. File edits arrive as one apply_patch call whose tool_input.command is
#      the whole patch, not as Write/Edit calls with file_path and content.
#      The adapter parses the patch and replays each file as the Write (Add
#      File) or Edit (Update File) payload the edit gates and reminders read.
#   2. Codex rejects permissionDecision "ask" (and "allow"). A hook that asks
#      for confirmation is translated per CLAUDE_CODEX_ASK_POLICY:
#        deny  (default) the call is denied with the hook's reason and a note
#                        that the user runs it themselves after confirming
#        allow           the call proceeds and the reason is injected as
#                        additionalContext telling the model to confirm first
#   3. The Bash(...) deny and ask rules of ~/.claude/settings.json are
#      evaluated on PreToolUse Bash, since Codex does not read that file.
#
# Usage (from ~/.codex/hooks.json, one entry per hook group; this file is
# copied to ~/.codex/hooks/ by openai/build.mjs):
#   codex-hook-adapter.sh <hook-name> [<hook-name> ...]
# where <hook-name> is a basename in ~/.claude/hooks/ without ".sh". Stdin is
# the Codex hook payload; stdout is the merged decision in Claude Code's
# hookSpecificOutput / decision shape, which Codex parses as is.
#
# Fail open: any adapter fault answers nothing (the call proceeds).
# Debug: CLAUDE_CODEX_HOOK_DEBUG=1 logs every payload and hook output to
# ~/.claude/.codex-hook-state/debug.log.

set -uo pipefail

HOOK_NAMES=("$@")
# The Claude Code configuration this port was generated from. Overridable so
# the fixture tests can run against a checkout that is not at ~/.claude.
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_HOOKS_DIR="${CLAUDE_HOOKS_DIR:-$CLAUDE_HOME/hooks}"
STATE_DIR="${CLAUDE_CODEX_STATE_DIR:-$CLAUDE_HOME/.codex-hook-state}"
ASK_POLICY="${CLAUDE_CODEX_ASK_POLICY:-deny}"
# shellcheck source=../../enforce/settingsPermissionRules.sh
source "$CLAUDE_HOME/enforce/settingsPermissionRules.sh" 2>/dev/null || true

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""')
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"
[ -d "$CWD" ] && cd "$CWD" 2>/dev/null

debug() {
  [ -n "${CLAUDE_CODEX_HOOK_DEBUG:-}" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >>"$STATE_DIR/debug.log" 2>/dev/null || true
}
debug "in:$EVENT:$TOOL" "$INPUT"

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
  [ -x "$script" ] || { debug "missing" "$script"; return 0; }
  err_file=$(mktemp)
  HOOK_OUT=$(printf '%s' "$payload" | "$script" 2>"$err_file")
  HOOK_STATUS=$?
  HOOK_ERR=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  debug "out:$name:$HOOK_STATUS" "$HOOK_OUT"
  return 0
}

json_field() {
  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true
}

append_text() {
  if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s\n\n%s' "$1" "$2"; fi
}

WORST="allow"
REASONS=""
CONTEXT=""
SYSTEM_MESSAGE=""

rank() {
  case "$1" in deny) echo 3 ;; ask) echo 2 ;; *) echo 1 ;; esac
}

absorb_decision() {
  local decision reason ctx
  decision=$(json_field "$HOOK_OUT" '.hookSpecificOutput.permissionDecision')
  reason=$(json_field "$HOOK_OUT" '.hookSpecificOutput.permissionDecisionReason')
  if [ -z "$decision" ] && [ "$(json_field "$HOOK_OUT" '.decision')" = "block" ]; then
    decision="deny"
    reason=$(json_field "$HOOK_OUT" '.reason')
  fi
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
  [ -n "$ctx" ] && SYSTEM_MESSAGE=$(append_text "$SYSTEM_MESSAGE" "$ctx")
  return 0
}

run_all() {
  local name
  for name in "${HOOK_NAMES[@]+"${HOOK_NAMES[@]}"}"; do
    run_hook "$name" "$1"
    absorb_decision
  done
}

# --- apply_patch: replay each file as the Write or Edit call the hooks read ---

# Streams the patch as tagged lines the loop below accumulates per file:
#   F<TAB><add|update><TAB><path>   starts a file
#   O<TAB><text>                    a line of the old text (Update File only)
#   N<TAB><text>                    a line of the new text
# Deleted and moved files carry no content the gates read and are skipped.
patch_lines() {
  printf '%s\n' "$1" | awk '
    /^\*\*\* Add File: / { active = 1; printf "F\tadd\t%s\n", substr($0, 15); next }
    /^\*\*\* Update File: / { active = 1; printf "F\tupdate\t%s\n", substr($0, 18); next }
    /^\*\*\* Delete File: / { active = 0; next }
    /^\*\*\* (Begin|End) Patch/ { active = 0; next }
    /^\*\*\* Move to: / { next }
    /^@@/ { next }
    active && /^\+/ { printf "N\t%s\n", substr($0, 2); next }
    active && /^-/ { printf "O\t%s\n", substr($0, 2); next }
    active && /^ / { printf "O\t%s\nN\t%s\n", substr($0, 2), substr($0, 2); next }
  '
}

replay_file() {
  # $1 = Claude event, $2 = kind, $3 = path, $4 = old text, $5 = new text
  local file payload
  case "$3" in /*) file="$3" ;; *) file="$CWD/$3" ;; esac
  if [ "$2" = "add" ]; then
    payload=$(printf '%s' "$INPUT" | jq --arg e "$1" --arg f "$file" --arg c "$5" \
      '. + {hook_event_name:$e, tool_name:"Write", tool_input:{file_path:$f, content:$c}}')
  else
    payload=$(printf '%s' "$INPUT" | jq --arg e "$1" --arg f "$file" --arg o "$4" --arg n "$5" \
      '. + {hook_event_name:$e, tool_name:"Edit", tool_input:{file_path:$f, old_string:$o, new_string:$n}}')
  fi
  run_all "$payload"
}

replay_patch() {
  # $1 = Claude event name, $2 = patch text. Runs the hooks once per file.
  local tag rest kind="" path="" old="" new=""
  while IFS=$'\t' read -r tag rest; do
    case "$tag" in
      F)
        [ -n "$path" ] && replay_file "$1" "$kind" "$path" "$old" "$new"
        kind="${rest%%$'\t'*}"
        path="${rest#*$'\t'}"
        old=""
        new=""
        ;;
      O) old="$old$rest"$'\n' ;;
      N) new="$new$rest"$'\n' ;;
    esac
  done < <(patch_lines "$2")
  [ -n "$path" ] && replay_file "$1" "$kind" "$path" "$old" "$new"
  return 0
}

# --- output in Codex's (Claude Code's) shape ---------------------------------------

emit_pre_tool_use() {
  local message
  if [ "$WORST" = "ask" ]; then
    if [ "$ASK_POLICY" = "allow" ]; then
      CONTEXT=$(append_text "CONFIRM WITH THE USER BEFORE PROCEEDING (Claude Code would pause here for approval; Codex hooks cannot, so this call is running): $REASONS" "$CONTEXT")
      WORST="allow"
    else
      WORST="deny"
      REASONS="Claude Code would ask for confirmation here; Codex hooks cannot pause for it, so the call is denied. $REASONS Ask the user; once they confirm, they run it themselves, or set CLAUDE_CODEX_ASK_POLICY=allow in Codex's environment to turn asks into context notes."
    fi
  fi
  if [ "$WORST" = "deny" ]; then
    message="$REASONS"
    [ -n "$CONTEXT" ] && message=$(append_text "$message" "$CONTEXT")
    jq -n --arg r "$message" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
    return 0
  fi
  [ -n "$CONTEXT" ] && jq -n --arg c "$CONTEXT" '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$c}}'
  return 0
}

emit_post_tool_use() {
  if [ "$WORST" = "deny" ]; then
    jq -n --arg r "$REASONS" '{decision:"block", reason:$r}'
    return 0
  fi
  [ -n "$CONTEXT" ] && jq -n --arg c "$CONTEXT" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}'
  return 0
}

emit_context_only() {
  # SessionStart and SessionEnd: only additionalContext and systemMessage carry.
  local event="$1"
  if [ -n "$CONTEXT" ] || [ -n "$SYSTEM_MESSAGE" ]; then
    jq -n --arg e "$event" --arg c "$CONTEXT" --arg s "$SYSTEM_MESSAGE" \
      '{hookSpecificOutput:{hookEventName:$e, additionalContext:$c}} + (if $s != "" then {systemMessage:$s} else {} end)'
  fi
  return 0
}

emit_stop() {
  if [ "$WORST" = "deny" ]; then
    jq -n --arg r "$REASONS" '{decision:"block", reason:$r}'
  fi
  return 0
}

# --- dispatch ------------------------------------------------------------------------

case "$EVENT" in
  PreToolUse)
    if [ "$TOOL" = "apply_patch" ]; then
      replay_patch PreToolUse "$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
    else
      if [ "$TOOL" = "Bash" ]; then
        CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
        if type matching_bash_rule >/dev/null 2>&1; then
          if RULE=$(matching_bash_rule deny "$CMD"); then
            WORST="deny"
            REASONS="settings.json denies \`Bash($RULE)\` (Claude Code permissions.deny, mirrored under Codex). A human runs this manually if it is genuinely required."
          elif RULE=$(matching_bash_rule ask "$CMD"); then
            WORST="ask"
            REASONS="settings.json asks before \`Bash($RULE)\` (Claude Code permissions.ask, mirrored under Codex)."
          fi
        fi
      fi
      run_all "$INPUT"
    fi
    emit_pre_tool_use
    ;;
  PostToolUse)
    if [ "$TOOL" = "apply_patch" ]; then
      replay_patch PostToolUse "$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
    else
      run_all "$INPUT"
    fi
    emit_post_tool_use
    ;;
  Stop | SubagentStop)
    run_all "$INPUT"
    emit_stop
    ;;
  SessionStart | SessionEnd | PostCompact | UserPromptSubmit)
    run_all "$INPUT"
    emit_context_only "$EVENT"
    ;;
  *)
    run_all "$INPUT"
    ;;
esac
exit 0
