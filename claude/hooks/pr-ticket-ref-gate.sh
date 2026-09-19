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

# The shell scanner and the R-605 range checks live in two sourced helpers
# shared with draft-pr-on-first-push.sh (IAN-137). Each is sourced behind an
# [ -f ] guard; a missing helper is reported as an ask once the command is
# known to be a gh pr create, so the gate never fails open in silence.
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"
HELPERS_LOADED=1
for helper in shell-command-scan.sh pr-range-checks.sh; do
  # shellcheck source=/dev/null
  if [ -f "$HOOK_DIR/$helper" ]; then source "$HOOK_DIR/$helper"; else HELPERS_LOADED=0; fi
done

# A cheap prefilter only: a command that mentions the words reaches the
# shell-aware scan below, which decides whether gh pr create really runs.
PREFILTER_PATTERN='gh[[:space:]]+pr[[:space:]]+(create|new)'

# parse_invocation_flags: reads the body, body file, and base out of
# INVOCATION_ARGS word by word, so a flag spelled inside another argument's
# quoted value (a title mentioning --body) is never taken for the flag.
parse_invocation_flags() {
  local arg expected=''
  BODY_TEXT=''; BODY_FILE=''; BASE_NAME=''
  for arg in ${INVOCATION_ARGS[@]+"${INVOCATION_ARGS[@]}"}; do
    case "$expected" in
      body) BODY_TEXT="$arg"; expected=''; continue ;;
      file) BODY_FILE="$arg"; expected=''; continue ;;
      base) BASE_NAME="$arg"; expected=''; continue ;;
    esac
    case "$arg" in
      --body|-b) expected='body' ;;
      --body=*) BODY_TEXT="${arg#--body=}" ;;
      --body-file|-F) expected='file' ;;
      --body-file=*) BODY_FILE="${arg#--body-file=}" ;;
      --base|-B) expected='base' ;;
      --base=*) BASE_NAME="${arg#--base=}" ;;
    esac
  done
}

# body_has_reference: true when --body, a readable --body-file, or the
# heredoc behind `--body-file -` carries a Refs line.
body_has_reference() {
  local file="$BODY_FILE"
  has_refs_line "$BODY_TEXT" && return 0
  if [ "$file" = "-" ]; then has_refs_line "$INVOCATION_STDIN"; return; fi
  [ -n "$file" ] || return 1
  case "$file" in "~"/*) file="$HOME/${file#\~/}" ;; /*) ;; *) file="$TARGET_DIR/$file" ;; esac
  [ -f "$file" ] && has_refs_line "$(cat "$file" 2>/dev/null)"
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
  [ -n "$1" ] || note=" No repository or base branch could be resolved, so the commits were not read; the body alone was checked."
  record_fire "deny"
  jq -nc --arg r "R-605 (ticket reference): no commit in this pull request and no --body/--body-file text carries a \`Refs: <KEY>\` line (KEY like IAN-119; a bare rule ID or key does not count). Open the ticket with /ticket-lifecycle, then add \`Refs: <KEY>\` as a commit trailer or a line of the PR body. Exempt: docs-only changes and a trivial tier recorded by task-tier.sh for this branch.${note}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // "" | strings' 2>/dev/null <<< "$INPUT" || true)
grep -Eq -- "$PREFILTER_PATTERN" <<< "$CMD" || exit 0
if [ "$HELPERS_LOADED" -ne 1 ]; then
  jq -nc --arg r "R-605 (ticket reference): pr-ticket-ref-gate.sh could not load its helpers (shell-command-scan.sh, pr-range-checks.sh) beside it, so this pull request's ticket reference is unchecked. Re-run ./sync.sh, or confirm the PR carries a \`Refs: <KEY>\` line." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
fi

SESSION_DIR=$(jq -r '.cwd // "" | strings' 2>/dev/null <<< "$INPUT" || true)
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || SESSION_DIR="$PWD"
# Read the command as shell: the cds before the invocation decide the
# directory, and only the invocation's own words supply the body and flags,
# so quoted text, an earlier `-b`, or a later command's heredoc or `-F` is
# never taken for the pull request's.
scan_command_tokens "$CMD"
find_simple_command "$SESSION_DIR" is_pr_create_command || exit 0
parse_invocation_flags

body_has_reference && exit 0
# Outside a repository (gh pr create -R owner/repo --head branch) there are
# no commits or ledger to read; the body was the only source, so the call
# falls through to the tracker check and the deny rather than exiting open.
TOP=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)
BASE=""
if [ -n "$TOP" ]; then
  BASE=$(resolve_pr_base "$BASE_NAME" "$TOP")
  commits_have_reference "$TOP" "$BASE" && exit 0
  is_docs_only_range "$TOP" "$BASE" && exit 0
  is_trivial_tier "$TOP" && exit 0
fi
if [ ! -f "$HOME/.claude/TICKET-TRACKER.json" ]; then
  emit_degraded_warning
  exit 0
fi
emit_deny "$BASE"
exit 0
