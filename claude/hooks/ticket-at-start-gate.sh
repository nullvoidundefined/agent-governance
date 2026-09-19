#!/usr/bin/env bash
# ticket-at-start-gate.sh: PreToolUse(Write|Edit|Bash) gate that makes the
# tracker ticket a precondition of the work rather than of the pull request
# (R-605, IAN-149). pr-ticket-ref-gate.sh asks for a ticket only at
# `gh pr create`, by which point the whole task has run, so tickets were filed
# after the merge. This hook denies the first Write or Edit, and every
# `git commit`, in a repository whose task-start ledger (.claude/task-tier.json)
# does not carry the ticket for the branch checked out.
#
# The ledger passes when it is untracked (session state, not something a
# branch can ship), names the current branch, and records either the trivial
# tier (R-605 asks for no ticket there) or a ticket key written by
# `task-tier.sh set <tier> "<reason>" --ticket <KEY>`. Nothing is gated when no
# tracker is configured (~/.claude/TICKET-TRACKER.json absent, R-605's degraded
# path), outside a git work tree, on a detached HEAD (a rebase or bisect in
# progress), or for a path under the repository's own .claude/ directory or one
# git ignores. Edits made through Bash (sed, a script) skip the Write/Edit
# matcher, which is why `git commit` is gated as well: no work reaches history
# without the ticket.
#
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail
INPUT=$(cat)
[ -f "$HOME/.claude/TICKET-TRACKER.json" ] || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"

# deny <reason>: emits the PreToolUse deny decision and logs the rule fire.
deny() {
  [ -f "$HOOK_DIR/log-rule-fire.sh" ] && source "$HOOK_DIR/log-rule-fire.sh"
  type log_rule_fire >/dev/null 2>&1 && log_rule_fire "R-605" "ticket-at-start-gate" "deny"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# resolve_edit_directory <file-path>: prints the nearest existing directory
# holding the file, physical path, so a new file under directories that do not
# exist yet is judged by the repository it would land in.
resolve_edit_directory() {
  local directory
  case "$1" in /*) directory=$(dirname "$1") ;; *) directory=$(dirname "$CWD/$1") ;; esac
  while [ ! -d "$directory" ] && [ "$directory" != "/" ]; do directory=$(dirname "$directory"); done
  (cd "$directory" 2>/dev/null && pwd -P)
}

# resolve_edit_path <file-path>: prints the file's physical path: the nearest
# existing ancestor resolved through symlinks, followed by the components that
# do not exist yet, so `.claude/new/x` keeps its `.claude/new` part.
resolve_edit_path() {
  local absolute_path existing_directory missing_suffix
  case "$1" in /*) absolute_path="$1" ;; *) absolute_path="$CWD/$1" ;; esac
  existing_directory=$(dirname "$absolute_path")
  missing_suffix=$(basename "$absolute_path")
  while [ ! -d "$existing_directory" ] && [ "$existing_directory" != "/" ]; do
    missing_suffix="$(basename "$existing_directory")/$missing_suffix"
    existing_directory=$(dirname "$existing_directory")
  done
  printf '%s/%s' "$(cd "$existing_directory" 2>/dev/null && pwd -P)" "$missing_suffix"
}

# is_exempt_edit_path <top> <file-path>: true for a path under the
# repository's .claude/ directory or one git ignores.
is_exempt_edit_path() {
  local top="$1" physical_path
  physical_path=$(resolve_edit_path "$2")
  case "$physical_path" in "$top/.claude/"*) return 0 ;; esac
  git -C "$top" check-ignore -q -- "$physical_path" 2>/dev/null
}

# read_commit_directory: prints the directory a `git commit` in the command
# runs against (the payload cwd, or a `git -C`/`--work-tree` target), or
# nothing when the command runs no commit.
read_commit_directory() {
  local command_text target_directory=""
  command_text=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
  if [ -f "$HOOK_DIR/git-invocation.sh" ]; then
    source "$HOOK_DIR/git-invocation.sh"
    grep -qE '(^|[;&|(])[[:space:]]*git[[:space:]]+commit([[:space:]]|$)' <<< "$(printf '%s' "$command_text" | strip_git_global_options)" || return 0
    parse_git_target_options "$command_text" commit
    target_directory=$(read_git_target_directory)
  else
    grep -qE '(^|[;&|(])[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit([[:space:]]|$)' <<< "$command_text" || return 0
    target_directory=$(printf '%s' "$command_text" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' | head -1 | awk '{print $3}')
  fi
  case "$target_directory" in "") printf '%s' "$CWD" ;; /*) printf '%s' "$target_directory" ;; *) printf '%s' "$CWD/$target_directory" ;; esac
}

# read_ledger_problem <top> <branch>: prints why the ledger does not carry the
# ticket for this branch, or nothing when it does.
read_ledger_problem() {
  local top="$1" branch="$2" ledger="$1/.claude/task-tier.json" ledger_branch
  [ -f "$ledger" ] || { echo "no task-start ledger (.claude/task-tier.json) is recorded in this checkout"; return 0; }
  if git -C "$top" ls-files --error-unmatch .claude/task-tier.json >/dev/null 2>&1; then
    echo "the ledger .claude/task-tier.json is tracked by git, so it is not this session's task-start state"
    return 0
  fi
  jq -e 'type == "object"' "$ledger" >/dev/null 2>&1 || { echo "the ledger .claude/task-tier.json is unreadable (not the JSON task-tier.sh writes)"; return 0; }
  ledger_branch=$(jq -r '.branch // "" | strings' "$ledger")
  [ "$ledger_branch" = "$branch" ] || { echo "the ledger records branch '${ledger_branch}', not '${branch}', so it belongs to an earlier task"; return 0; }
  jq -e '.tier == "trivial" or ((.ticket // "") | test("^[A-Z][A-Z0-9]+-[0-9]+$"))' "$ledger" >/dev/null 2>&1 ||
    echo "the ledger records the $(jq -r '.tier // "?"' "$ledger") tier with no ticket key"
}

case "$TOOL" in
  Write | Edit)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
    [ -n "$FILE_PATH" ] || exit 0
    WORK_DIRECTORY=$(resolve_edit_directory "$FILE_PATH")
    ACTION="editing $(basename "$FILE_PATH")" ;;
  Bash)
    WORK_DIRECTORY=$(read_commit_directory)
    ACTION="committing" ;;
  *) exit 0 ;;
esac
[ -n "$WORK_DIRECTORY" ] || exit 0
TOP=$(git -C "$WORK_DIRECTORY" rev-parse --show-toplevel 2>/dev/null) || exit 0
TOP=$(cd "$TOP" && pwd -P)
if [ "$TOOL" != "Bash" ] && is_exempt_edit_path "$TOP" "$FILE_PATH"; then exit 0; fi
BRANCH=$(git -C "$TOP" branch --show-current 2>/dev/null)
[ -n "$BRANCH" ] || exit 0
PROBLEM=$(read_ledger_problem "$TOP" "$BRANCH")
[ -z "$PROBLEM" ] && exit 0
deny "R-605 (ticket at task start): $ACTION on branch '$BRANCH' is refused because $PROBLEM. The ticket comes before the work: open it with /ticket-lifecycle, then record it on this branch with \`bash ~/.claude/skills/task-start/scripts/task-tier.sh set <tier> \"<reason>\" --ticket <KEY>\` (a trivial task records \`task-tier.sh set trivial \"<reason>\"\` and needs no ticket). When the work already happened without a ticket, open it retroactively with its actuals and then record it."
