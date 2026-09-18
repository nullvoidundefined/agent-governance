#!/usr/bin/env bash
# pr-ticket-ref-gate.sh: on `gh pr create`, deny a pull request that carries
# no tracker ticket reference (R-605). A reference is a line of the form
# `Refs: <KEY>`, KEY matching [A-Z][A-Z0-9]+-[0-9]+, found either in the
# message of a commit in the pull request's range or in the body passed with
# --body/-b or --body-file/-F. The `Refs:` form is required rather than a bare
# key match, because rule IDs (R-605) and strings such as SHA-256 would
# otherwise read as ticket keys.
#
# Three exemptions, in order: a range whose every changed path is a Markdown
# file or sits under docs/ (a docs-only change needs no ticket); a task-start
# ledger (.claude/task-tier.json) recording the trivial tier for the current
# branch, since R-605 asks for a ticket only above the trivial tier; and an
# absent ~/.claude/TICKET-TRACKER.json, where R-605's degraded path applies,
# so the call is allowed with a warning in the hook's context and never in
# silence.
#
# Base: the pull request's base branch (--base/-B, else origin's default
# branch, else main or master), merged with HEAD. resolve-outgoing-base.sh is
# deliberately not used: its first choice is the branch's own push tracking
# ref, and a branch is normally pushed before its pull request is opened, so
# that range would be empty and every PR would read as carrying no commits.
# CLAUDE_ENFORCE_BASE still overrides, as it does for every push gate.
#
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

KEY_PATTERN='[A-Z][A-Z0-9]+-[0-9]+'
REFS_LINE_PATTERN="^[[:space:]\"']*Refs:[[:space:]]*${KEY_PATTERN}([^A-Za-z0-9-]|\$)"
CREATE_PATTERN='(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+(create|new)([[:space:]]|$)'

# has_refs_line <text>: true when some line of the text is a Refs trailer
# naming a ticket key, optionally preceded by an opening quote.
has_refs_line() {
  grep -Eq -- "$REFS_LINE_PATTERN" <<< "$1"
}

# resolve_target_dir <command> <session-cwd>: prints the directory the pull
# request is created from, honoring a leading `cd <dir>` in the command and
# falling back to the session's working directory.
resolve_target_dir() {
  local command="$1" session_dir="$2" cd_pattern cd_dir
  cd_pattern="(^|[;&|(])[[:space:]]*cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)"
  if [[ "$command" =~ $cd_pattern ]]; then
    cd_dir="${BASH_REMATCH[2]}"
    cd_dir="${cd_dir#[\"\']}"; cd_dir="${cd_dir%[\"\']}"
    case "$cd_dir" in "~"/*) cd_dir="$HOME/${cd_dir#\~/}" ;; /*) ;; *) cd_dir="$session_dir/$cd_dir" ;; esac
    [ -d "$cd_dir" ] && { printf '%s' "$cd_dir"; return; }
  fi
  printf '%s' "$session_dir"
}

# body_flag_text <command>: prints everything after the first --body/-b flag,
# so that a heredoc body keeps its line structure; empty when there is none.
body_flag_text() {
  local command="$1" body_pattern='(^|[[:space:]])(--body|-b)([[:space:]]+|=)(.*)'
  [[ "$command" =~ $body_pattern ]] && printf '%s' "${BASH_REMATCH[4]}"
}

# body_file_path <command> <target-dir>: prints the path passed with
# --body-file/-F, resolved against the target directory; empty for none or
# for `-` (standard input, which a hook cannot read).
body_file_path() {
  local command="$1" dir="$2" path file_pattern
  file_pattern="(^|[[:space:]])(--body-file|-F)([[:space:]]+|=)(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)"
  [[ "$command" =~ $file_pattern ]] || return 0
  path="${BASH_REMATCH[4]}"
  path="${path#[\"\']}"; path="${path%[\"\']}"
  [ "$path" = "-" ] && return 0
  case "$path" in "~"/*) path="$HOME/${path#\~/}" ;; /*) ;; *) path="$dir/$path" ;; esac
  printf '%s' "$path"
}

# body_has_reference <command> <target-dir>: true when the body given by
# --body or by a readable --body-file carries a Refs line.
body_has_reference() {
  local command="$1" dir="$2" file
  has_refs_line "$(body_flag_text "$command")" && return 0
  file=$(body_file_path "$command" "$dir")
  [ -n "$file" ] && [ -f "$file" ] && has_refs_line "$(cat "$file" 2>/dev/null)"
}

# resolve_pr_base <command> <target-dir>: prints the merge base of HEAD with
# the pull request's base branch; empty when none of the candidates exist.
resolve_pr_base() {
  local command="$1" dir="$2" base_pattern named="" default="" candidate merge_base
  if [ -n "${CLAUDE_ENFORCE_BASE:-}" ]; then printf '%s' "$CLAUDE_ENFORCE_BASE"; return; fi
  base_pattern="(^|[[:space:]])(--base|-B)([[:space:]]+|=)[\"']?([^[:space:]\"';&|]+)"
  [[ "$command" =~ $base_pattern ]] && named="${BASH_REMATCH[4]}"
  default=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  for candidate in ${named:+"origin/$named" "$named"} ${default:+"$default"} origin/main main origin/master master; do
    git -C "$dir" rev-parse --verify -q "$candidate" >/dev/null 2>&1 || continue
    merge_base=$(git -C "$dir" merge-base "$candidate" HEAD 2>/dev/null || true)
    [ -n "$merge_base" ] && { printf '%s' "$merge_base"; return; }
  done
}

# commits_have_reference <target-dir> <base>: true when a commit message in
# base..HEAD carries a Refs line.
commits_have_reference() {
  local dir="$1" base="$2"
  [ -n "$base" ] || return 1
  has_refs_line "$(git -C "$dir" log --format=%B "$base..HEAD" 2>/dev/null)"
}

# is_docs_only_range <target-dir> <base>: true when the range changes at
# least one path and every changed path is *.md or under docs/. An empty or
# unreadable range is not docs-only, so it cannot exempt anything.
is_docs_only_range() {
  local dir="$1" base="$2" changed
  [ -n "$base" ] || return 1
  changed=$(git -C "$dir" diff --name-only "$base...HEAD" 2>/dev/null) || return 1
  [ -n "$changed" ] || return 1
  ! grep -Evq '(\.md$|^docs/)' <<< "$changed"
}

# is_trivial_tier <repo-top>: true when task-start's ledger records the
# trivial tier for the branch currently checked out (a ledger left from an
# earlier branch does not count).
is_trivial_tier() {
  local top="$1" ledger="$1/.claude/task-tier.json" branch
  [ -f "$ledger" ] || return 1
  branch=$(git -C "$top" branch --show-current 2>/dev/null || true)
  jq -e --arg b "$branch" '.tier == "trivial" and ((.branch // "") == "" or .branch == $b)' "$ledger" >/dev/null 2>&1
}

# record_fire <decision>: logs one R-605 fire through the shared telemetry
# helper when it is present.
record_fire() {
  local helper
  helper="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  # shellcheck source=log-rule-fire.sh
  [ -f "$helper" ] && source "$helper"
  type log_rule_fire >/dev/null 2>&1 && log_rule_fire "R-605" "pr-ticket-ref-gate" "$1"
  return 0
}

# emit_degraded_warning: allows the call with context naming R-605's
# degraded path, for a machine with no tracker configured.
emit_degraded_warning() {
  record_fire "warn"
  jq -nc --arg m "R-605 (ticket reference): this pull request carries no \`Refs: <KEY>\` line in its commits or body, and no tracker is configured (~/.claude/TICKET-TRACKER.json is absent), so it proceeds on R-605's degraded path. Record the ticket field set (title, tier, assist, model, estimate, repo, branch) in docs/session-handoff/session-handoff.md, and copy ~/.claude/TICKET-TRACKER.template.json to TICKET-TRACKER.json to turn the tracker on." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
}

# emit_deny <base>: denies the call, naming R-605 and the fix.
emit_deny() {
  local note=""
  [ -n "$1" ] || note=" The pull request's base could not be resolved, so the commits were not read; the body alone was checked."
  record_fire "deny"
  jq -nc --arg r "R-605 (ticket reference): no commit in this pull request and no --body/--body-file text carries a \`Refs: <KEY>\` line (KEY like IAN-119; a bare rule ID or key does not count). Open the ticket with /ticket-lifecycle, then add \`Refs: <KEY>\` as a commit trailer or a line of the PR body. Exempt: docs-only changes and a trivial tier recorded by task-tier.sh for this branch.${note}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // "" | strings' 2>/dev/null <<< "$INPUT" || true)
grep -Eq -- "$CREATE_PATTERN" <<< "$CMD" || exit 0

SESSION_DIR=$(jq -r '.cwd // "" | strings' 2>/dev/null <<< "$INPUT" || true)
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || SESSION_DIR="$PWD"
TARGET_DIR=$(resolve_target_dir "$CMD" "$SESSION_DIR")
# The flags are read from the gh invocation onward, so that a `-b` or `-F`
# belonging to an earlier command in the chain (git switch -b) is not taken
# for the pull request's body.
GH_PATTERN='gh[[:space:]]+pr[[:space:]]+(create|new)(.*)'
GH_TEXT="$CMD"
[[ "$CMD" =~ $GH_PATTERN ]] && GH_TEXT="${BASH_REMATCH[2]}"
TOP=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$TOP" ] || exit 0

body_has_reference "$GH_TEXT" "$TARGET_DIR" && exit 0
BASE=$(resolve_pr_base "$GH_TEXT" "$TOP")
commits_have_reference "$TOP" "$BASE" && exit 0
is_docs_only_range "$TOP" "$BASE" && exit 0
is_trivial_tier "$TOP" && exit 0
if [ ! -f "$HOME/.claude/TICKET-TRACKER.json" ]; then
  emit_degraded_warning
  exit 0
fi
emit_deny "$BASE"
exit 0
