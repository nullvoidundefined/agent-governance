#!/usr/bin/env bash
# codex-hook-adapter.sh
#
# Runs the Claude Code hooks under OpenAI Codex. Codex's hooks.json uses the
# same schema, events, stdin fields, and stdout fields as Claude Code, so
# nearly every hook could be wired directly. Four things differ, and this
# adapter is where they are handled so the hook scripts stay untouched:
#
#   1. File edits arrive as one apply_patch call whose tool_input.command is
#      the whole patch, not as Write/Edit calls with file_path and content.
#      The adapter parses the patch and replays each operation as the call the
#      gates already read: Add File as Write, Update File as Edit, Delete File
#      as the Bash `rm` a Claude Code session would have run (Claude Code has
#      no delete tool, so `rm` is the shape its guards are written against),
#      and Move to as the Bash `mv`, which puts both the source and the
#      destination in front of the guard. Before 2026-09-18 a Delete File
#      dispatched no event at all and a Move destination was discarded, so a
#      locked test could be deleted, or a file renamed into a protected tree,
#      with protected-path-guard never seeing it.
#   2. Codex rejects permissionDecision "ask" (and "allow"). A hook that asks
#      for confirmation is translated per CLAUDE_CODEX_ASK_POLICY:
#        deny  (default) the call is denied with the hook's reason and a note
#                        that the user runs it themselves after confirming
#        allow           the call proceeds and the reason is injected as
#                        additionalContext telling the model to confirm first
#   3. The Bash(...) deny and ask rules of ~/.claude/settings.json are
#      evaluated on PreToolUse Bash, since Codex does not read that file. The
#      matching lives in ~/.claude/enforce/settings-permission-rules.sh, which
#      this adapter sources; if that helper cannot be loaded the permission
#      layer FAILS CLOSED, denying the call and saying so, because a mirror
#      that stops mirroring is indistinguishable from an allow and the port
#      status page still claims the rules are enforced.
#   4. apply_patch is not the only door Codex writes files through. Asked to
#      edit a file, Codex often runs a shell command instead, and a shell
#      command reaches the hooks as one PreToolUse Bash event whose tool_input
#      carries a command string and no path at all. Codex registers the
#      write-target gates (structure-gate, content-gate, dependency-add-guard,
#      migration-defaults-guard, codex-test-author-guard) on the Write|Edit
#      matcher, so before 2026-09-18 none of them ever saw a file written by a
#      redirection: the same edit was denied through apply_patch and allowed
#      through `printf ... > path`. The adapter now extracts the write targets
#      out of the command text and dispatches one synthetic Write event per
#      target to those gates, IN ADDITION to the ordinary Bash event, which
#      still runs unchanged. See the extractor section below for exactly what
#      that analysis catches and what it cannot.
#
# Usage (from ~/.codex/hooks.json, one entry per hook group; this file is
# copied to ~/.codex/hooks/ by openai/build.mjs):
#   codex-hook-adapter.sh <hook-name> [<hook-name> ...]
# where <hook-name> is a basename in ~/.claude/hooks/ without ".sh". Stdin is
# the Codex hook payload; stdout is the merged decision in Claude Code's
# hookSpecificOutput / decision shape, which Codex parses as is.
#
# Fail open: any adapter fault answers nothing (the call proceeds). The one
# deliberate exception is the permission layer above, which fails closed: an
# adapter that cannot evaluate the deny rules has not decided that the command
# is safe, it has only lost the ability to say otherwise.
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
CLAUDE_ENFORCE_DIR="${CLAUDE_ENFORCE_DIR:-$CLAUDE_HOME/enforce}"
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$CLAUDE_HOME/settings.json}"
PERMISSION_RULES_FILE="${CLAUDE_PERMISSION_RULES_FILE:-$CLAUDE_ENFORCE_DIR/settings-permission-rules.sh}"

# The gates Codex registers on the Write|Edit matcher, which is why a file
# written by a shell command reaches none of them on its own. A synthetic write
# event goes to exactly this list. It is written out here rather than derived,
# because the adapter is handed only its own matcher's hook names; the fixture
# codex-adapter-contract.test.sh compares this list against the Write|Edit
# registration in codex/hooks.json, so a settings.json change that moves a gate
# in or out of that group fails a test instead of silently narrowing the port.
# Overridable so the fixtures can observe what is dispatched; setting it empty
# turns the synthetic dispatch off.
read -r -a CODEX_WRITE_TARGET_HOOKS <<<"${CLAUDE_CODEX_WRITE_TARGET_HOOKS-secret-scan no-em-dash migration-defaults-guard structure-gate content-gate protected-path-guard dependency-add-guard codex-test-author-guard}"

# The permission helper is resolved deterministically and its absence is
# recorded rather than swallowed. PERMISSION_RULES_ERROR non-empty means the
# Bash(...) rules cannot be evaluated at all, and every Bash call is denied
# with that text until the install is repaired.
PERMISSION_RULES_ERROR=""
if [ -r "$PERMISSION_RULES_FILE" ]; then
  # shellcheck source=../../claude/enforce/settings-permission-rules.sh
  source "$PERMISSION_RULES_FILE" \
    || PERMISSION_RULES_ERROR="The settings.json permission rules could not be loaded from $PERMISSION_RULES_FILE (the file is there but failed to source), so the Bash(...) deny and ask rules mirrored from Claude Code cannot be evaluated."
else
  PERMISSION_RULES_ERROR="The settings.json permission rules are missing: no readable settings-permission-rules.sh at $PERMISSION_RULES_FILE, so the Bash(...) deny and ask rules mirrored from Claude Code cannot be evaluated. Reinstall the harness (sync.sh) or set CLAUDE_HOME to the Claude Code configuration this port was built from."
fi
if [ -z "$PERMISSION_RULES_ERROR" ] && ! type matching_bash_rule >/dev/null 2>&1; then
  PERMISSION_RULES_ERROR="$PERMISSION_RULES_FILE loaded but defines no matching_bash_rule, so the Bash(...) deny and ask rules mirrored from Claude Code cannot be evaluated."
fi

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

# One guard can now be reached twice for a single call: once on the Bash event
# and once on the synthetic write event for the file that command creates.
# Identical text is collapsed so the denial the model reads says it once.
append_reason() {
  [ -n "$1" ] || return 0
  case "$REASONS" in *"$1"*) return 0 ;; esac
  REASONS=$(append_text "$REASONS" "$1")
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
      append_reason "$reason"
      ;;
  esac
  ctx=$(json_field "$HOOK_OUT" '.hookSpecificOutput.additionalContext')
  [ -n "$ctx" ] && CONTEXT=$(append_text "$CONTEXT" "$ctx")
  ctx=$(json_field "$HOOK_OUT" '.systemMessage')
  [ -n "$ctx" ] && SYSTEM_MESSAGE=$(append_text "$SYSTEM_MESSAGE" "$ctx")
  return 0
}

# Runs a named set of hooks over one payload. $1 is the payload, the rest are
# hook basenames, so the synthetic write events can be sent to the Write|Edit
# gates rather than to the hook list this invocation happened to be given.
run_hooks() {
  local payload="$1" name
  shift
  for name in "$@"; do
    run_hook "$name" "$payload"
    absorb_decision
  done
}

run_all() {
  run_hooks "$1" "${HOOK_NAMES[@]+"${HOOK_NAMES[@]}"}"
}

# --- the Bash(...) rules of settings.json -------------------------------------

# The permission layer's own failure mode. Denying here is the whole point: an
# adapter that cannot read the deny rules has not established that the command
# is permitted, and the old `|| true` turned exactly this state into an allow
# that nothing reported (2026-09-18 port audit).
permission_layer_failed() {
  WORST="deny"
  REASONS=$(append_text "$REASONS" "This command is denied because the mirrored Claude Code permission rules could not be evaluated, and an unreadable deny list is not permission to proceed. $1")
}

apply_bash_permission_rules() {
  local cmd="$1" rule status
  [ -n "$cmd" ] || return 0
  if [ -n "$PERMISSION_RULES_ERROR" ]; then
    permission_layer_failed "$PERMISSION_RULES_ERROR"
    return 0
  fi
  rule=$(matching_bash_rule deny "$cmd")
  status=$?
  if [ "$status" -eq 0 ]; then
    WORST="deny"
    REASONS=$(append_text "$REASONS" "settings.json denies \`Bash($rule)\` (Claude Code permissions.deny, mirrored under Codex). A human runs this manually if it is genuinely required.")
    return 0
  fi
  if [ "$status" -ge 2 ]; then
    permission_layer_failed "$SETTINGS_FILE is missing, unreadable, or not JSON, so no Bash(...) rule could be matched."
    return 0
  fi
  rule=$(matching_bash_rule ask "$cmd")
  status=$?
  if [ "$status" -eq 0 ]; then
    if [ "$(rank ask)" -gt "$(rank "$WORST")" ]; then WORST="ask"; fi
    REASONS=$(append_text "$REASONS" "settings.json asks before \`Bash($rule)\` (Claude Code permissions.ask, mirrored under Codex).")
    return 0
  fi
  [ "$status" -ge 2 ] && permission_layer_failed "$SETTINGS_FILE is missing, unreadable, or not JSON, so no Bash(...) rule could be matched."
  return 0
}

# --- apply_patch: replay each file as the Write or Edit call the hooks read ---

# Streams the patch as tagged lines the loop below accumulates per file:
#   F<TAB><add|update|delete><TAB><path>   starts a file
#   M<TAB><path>                           the current file's move destination
#   O<TAB><text>                           a line of the old text (update only)
#   N<TAB><text>                           a line of the new text
# A Delete File section carries no content, so it opens no content stream; the
# operation itself is still reported, because the path being deleted is exactly
# what the protected-path rules need to see.
patch_lines() {
  printf '%s\n' "$1" | awk '
    /^\*\*\* Add File: / { active = 1; printf "F\tadd\t%s\n", substr($0, 15); next }
    /^\*\*\* Update File: / { active = 1; printf "F\tupdate\t%s\n", substr($0, 18); next }
    /^\*\*\* Delete File: / { active = 0; printf "F\tdelete\t%s\n", substr($0, 18); next }
    /^\*\*\* Move to: / { printf "M\t%s\n", substr($0, 14); next }
    /^\*\*\* (Begin|End) Patch/ { active = 0; next }
    /^@@/ { next }
    active && /^\+/ { printf "N\t%s\n", substr($0, 2); next }
    active && /^-/ { printf "O\t%s\n", substr($0, 2); next }
    active && /^ / { printf "O\t%s\nN\t%s\n", substr($0, 2), substr($0, 2); next }
  '
}

# Paths named by a patch or by a shell command are relative to the call's cwd;
# the gates read absolute ones.
absolute_call_path() {
  case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CWD" "$1" ;; esac
}

replay_file() {
  # $1 = Claude event, $2 = kind, $3 = path, $4 = old text, $5 = new text
  local file payload
  file=$(absolute_call_path "$3")
  if [ "$2" = "add" ]; then
    payload=$(printf '%s' "$INPUT" | jq --arg e "$1" --arg f "$file" --arg c "$5" \
      '. + {hook_event_name:$e, tool_name:"Write", tool_input:{file_path:$f, content:$c}}')
  else
    payload=$(printf '%s' "$INPUT" | jq --arg e "$1" --arg f "$file" --arg o "$4" --arg n "$5" \
      '. + {hook_event_name:$e, tool_name:"Edit", tool_input:{file_path:$f, old_string:$o, new_string:$n}}')
  fi
  run_all "$payload"
}

# A deletion and a rename have no Write or Edit equivalent: under Claude Code
# they are shell commands, and the guards that govern them (protected-path-guard
# above all) read them out of tool_input.command. Replaying them in that shape
# is what lets a guard deny the deletion of a locked test, or a rename whose
# destination lands inside a protected tree.
replay_shell_operation() {
  # $1 = Claude event, $2 = the command text the gates should see
  local payload
  payload=$(printf '%s' "$INPUT" | jq --arg e "$1" --arg c "$2" \
    '. + {hook_event_name:$e, tool_name:"Bash", tool_input:{command:$c}}')
  run_all "$payload"
}

replay_operation() {
  # $1 = Claude event, $2 = kind, $3 = path, $4 = old, $5 = new, $6 = move destination
  if [ "$2" = "delete" ]; then
    replay_shell_operation "$1" "rm -- '$(absolute_call_path "$3")'"
  else
    replay_file "$1" "$2" "$3" "$4" "$5"
  fi
  [ -n "$6" ] || return 0
  replay_shell_operation "$1" "mv -- '$(absolute_call_path "$3")' '$(absolute_call_path "$6")'"
}

replay_patch() {
  # $1 = Claude event name, $2 = patch text. Runs the hooks once per operation.
  local tag rest kind="" path="" old="" new="" dest=""
  while IFS=$'\t' read -r tag rest; do
    case "$tag" in
      F)
        [ -n "$path" ] && replay_operation "$1" "$kind" "$path" "$old" "$new" "$dest"
        kind="${rest%%$'\t'*}"
        path="${rest#*$'\t'}"
        old=""
        new=""
        dest=""
        ;;
      M) dest="$rest" ;;
      O) old="$old$rest"$'\n' ;;
      N) new="$new$rest"$'\n' ;;
    esac
  done < <(patch_lines "$2")
  [ -n "$path" ] && replay_operation "$1" "$kind" "$path" "$old" "$new" "$dest"
  return 0
}

# --- the shell door: write targets inside a Bash command ----------------------
#
# WHAT THIS CATCHES, and nothing beyond it. A shell command is not statically
# analyzable in general, so this is a literal-token extractor, not a shell:
#   caught   output redirection, `> path` and `>> path`, at any fd (`2> path`)
#            and with the noclobber override (`>| path`), once per redirection
#            so a command line with several of them yields several targets
#   caught   `tee path` and `tee -a path`, including several operands, since
#            tee writes every file it is given
#   caught   the destination of `cp`, `mv`, and `install`, taken as the last
#            non-flag operand, with `sudo`, `command`, `env` and leading
#            VAR=value assignments stepped over first
#   caught   single-quoted and double-quoted operands, including paths that
#            contain spaces, and backslash escapes outside quotes
#   caught   redirections written inside `$(...)` or backticks, which really do
#            write the file they name
#   skipped  heredoc bodies, stripped before tokenizing, so a `>` in the text
#            being written is not mistaken for a redirection of its own
#   skipped  `>&2`, `2>&1`, `>(...)` process substitution, and /dev/* targets,
#            none of which name a file in the repository
#
# WHAT IT CANNOT DO, and no amount of pattern work would change it: a path that
# only exists once the shell has run is not visible to anything that refuses to
# run the shell, and this adapter refuses. A target built from a variable
# (`> "$out"`), from a command substitution (`> "$(mktemp)"`), from a glob, or
# from `eval` is dropped rather than guessed at, as is a file written by an
# interpreter from inside its own source (`python - <<PY`), by `dd of=`, by an
# editor, or by any tool whose argument convention is not one of the four verbs
# above. Redirection is the common shape and is now covered; the rest is not,
# and a reader must not take this section for total coverage. The backstop for
# what escapes here is unchanged: `tdd.sh green` compares locked-file hashes
# against the RED commit, which catches the write after the fact.

# Heredoc bodies are data, not shell. A `>` inside the text being written names
# nothing, so the bodies are removed before any token is read; the line opening
# the heredoc stays, because its own redirections are real.
strip_heredoc_bodies() {
  printf '%s' "$1" | awk '
    delim != "" { if ($0 == delim) delim = ""; next }
    {
      print
      if (match($0, /<<-?[ \t]*[A-Za-z_'"'"'"][^ \t;|&<>()]*/)) {
        delim = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", delim)
        gsub(/['"'"'"]/, "", delim)
      }
    }
  '
}

# Tokenizes a command into tab-separated lines the caller walks:
#   RED<TAB><path>   the operand of a `>` or `>>` redirection
#   TOK<TAB><word>   an ordinary word, quotes resolved
#   SEP              a statement, pipeline, or grouping boundary
# Quote state is tracked character by character, which is the only way an
# operand containing a space survives as one token.
shell_write_tokens() {
  printf '%s' "$1" | awk '
    BEGIN { q = sprintf("%c", 39) }
    function flush() {
      if (!started) return
      if (pending) { printf "RED\t%s\n", cur; pending = 0 } else printf "TOK\t%s\n", cur
      cur = ""; started = 0
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf)
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (sq) { if (c == q) sq = 0; else cur = cur c; started = 1; continue }
        if (dq) {
          if (c == "\\" && index("\"\\$`", substr(buf, i + 1, 1)) > 0) { i++; cur = cur substr(buf, i, 1) }
          else if (c == "\"") dq = 0
          else cur = cur c
          started = 1; continue
        }
        if (c == q) { sq = 1; started = 1; continue }
        if (c == "\"") { dq = 1; started = 1; continue }
        if (c == "\\") { i++; cur = cur substr(buf, i, 1); started = 1; continue }
        if (c == ">") {
          flush()
          if (substr(buf, i + 1, 1) == ">") i++
          if (substr(buf, i + 1, 1) == "|") i++
          if (substr(buf, i + 1, 1) == "&" || substr(buf, i + 1, 1) == "(") { i++; continue }
          pending = 1; continue
        }
        if (c == "<") { flush(); if (substr(buf, i + 1, 1) == "<") i++; continue }
        if (index(";|&(){}\n", c) > 0) { flush(); pending = 0; print "SEP"; continue }
        if (c == " " || c == "\t") { flush(); continue }
        cur = cur c; started = 1
      }
      flush()
      print "SEP"
    }
  '
}

# A token names a file only when it names it literally. Anything carrying a
# parameter expansion, a command substitution, or a glob would have to be run
# to be known, and a device node is not a file in the repository.
is_literal_path() {
  case "$1" in
    "" | /dev/* | -*) return 1 ;;
    *'$'* | '`'* | *'`'* | *'*'* | *'?'* | *'['*) return 1 ;;
  esac
  return 0
}

# The command word of one statement, with the wrappers that precede it stepped
# over, so `sudo cp`, `env FOO=1 cp` and `/bin/cp` all report `cp`.
statement_verb() {
  local token
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case "$token" in
      *=*) continue ;;
      sudo | command | env | nohup | time) continue ;;
    esac
    basename -- "$token"
    return 0
  done <<<"$1"
  return 0
}

# The operands of one statement: everything after the command word that is not
# a flag. `install -m 644 src dst` keeps 644 as an operand, which is harmless
# because only the last one is read as a destination.
statement_operands() {
  local token seen_verb=""
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if [ -z "$seen_verb" ]; then
      case "$token" in
        *=*) continue ;;
        sudo | command | env | nohup | time) continue ;;
      esac
      seen_verb="yes"
      continue
    fi
    case "$token" in -*) continue ;; esac
    printf '%s\n' "$token"
  done <<<"$1"
  return 0
}

# The files one statement writes through its own argument convention: every
# operand for tee, the last operand for the copying verbs.
statement_write_targets() {
  local verb operands count
  verb=$(statement_verb "$1")
  case "$verb" in tee | cp | mv | install) ;; *) return 0 ;; esac
  operands=$(statement_operands "$1")
  [ -n "$operands" ] || return 0
  if [ "$verb" = "tee" ]; then
    printf '%s\n' "$operands"
    return 0
  fi
  count=$(printf '%s\n' "$operands" | grep -c .)
  [ "$count" -ge 2 ] && printf '%s\n' "$operands" | tail -n 1
  return 0
}

# Every write target of one command line, one per line, unfiltered duplicates.
shell_write_targets() {
  local tag value statement=""
  while IFS=$'\t' read -r tag value; do
    case "$tag" in
      RED) is_literal_path "$value" && printf '%s\n' "$value" ;;
      TOK) statement="$statement$value"$'\n' ;;
      SEP)
        statement_write_targets "$statement"
        statement=""
        ;;
    esac
  done < <(shell_write_tokens "$(strip_heredoc_bodies "$1")")
  return 0
}

# Shows each file a shell command writes to the gates Codex registers on
# Write|Edit, as the Write call an equivalent Claude Code session would have
# made. The content is empty because a redirection's content is whatever the
# command prints, which is not known before it runs; the path checks are the
# point, and the text of the command itself is already read by the hooks that
# run on the Bash event.
replay_shell_writes() {
  local target file payload seen=$'\n'
  [ ${#CODEX_WRITE_TARGET_HOOKS[@]} -gt 0 ] || return 0
  while IFS= read -r target; do
    is_literal_path "$target" || continue
    file=$(absolute_call_path "$target")
    case "$seen" in *$'\n'"$file"$'\n'*) continue ;; esac
    seen="$seen$file"$'\n'
    payload=$(printf '%s' "$INPUT" | jq --arg f "$file" \
      '. + {tool_name:"Write", tool_input:{file_path:$f, content:""}}')
    debug "shell-write" "$file"
    run_hooks "$payload" "${CODEX_WRITE_TARGET_HOOKS[@]}"
  done < <(shell_write_targets "$1")
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
    elif [ "$TOOL" = "Bash" ]; then
      COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
      apply_bash_permission_rules "$COMMAND"
      run_all "$INPUT"
      replay_shell_writes "$COMMAND"
    else
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
