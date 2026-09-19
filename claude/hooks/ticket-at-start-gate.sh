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
# path; an unset HOME reaches no tracker config and counts the same), outside a
# git work tree, on a detached HEAD (a rebase or bisect in progress), or for a
# path under the repository's own .claude/ directory or one git ignores. Edits
# made through Bash (sed, a script) skip the Write/Edit matcher, which is why
# `git commit` is gated as well. Only `git commit` is: cherry-pick, revert, am,
# and merge also write commits and are not read here.
#
# Commits are found by the quote-aware shell scan shared with the other R-605
# hooks (shell-command-scan.sh), never by a regex over the raw text: every
# commit in the command is judged against the repository it really runs in,
# after cd and pushd, env assignments, wrappers (env, time, nice, command,
# sudo, timeout, xargs), shell keywords, and git's -C, --work-tree, and
# --git-dir. A commit inside a shell string (sh -c, eval) cannot be read, so
# it is denied rather than guessed at.
#
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail
INPUT=$(cat)
[ -n "${HOME:-}" ] && [ -f "$HOME/.claude/TICKET-TRACKER.json" ] || exit 0
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

# resolve_relative_directory <base> <path>: prints <path> made absolute
# against <base>, expanding a leading ~ as the shell would.
resolve_relative_directory() {
  case "$2" in
    "~") printf '%s' "$HOME" ;;
    "~"/*) printf '%s/%s' "$HOME" "${2#\~/}" ;;
    /*) printf '%s' "$2" ;;
    *) printf '%s' "$1/$2" ;;
  esac
}

# is_commit_subcommand <word>...: true when the words after `git` run
# `commit`: git's global options (and the values of -C, -c, --git-dir,
# --work-tree, --namespace) are skipped, and the first other word must be
# commit, so `git log --grep commit` is not a commit.
is_commit_subcommand() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) shift 2 2>/dev/null || shift ;;
      -*) shift ;;
      *) [ "$1" = "commit" ]; return ;;
    esac
  done
  return 1
}

# has_git_commit_in_string <word>...: true when a shell string (the words of
# sh -c or eval, quotes dropped) runs `git ... commit` anywhere in it.
has_git_commit_in_string() {
  local -a string_words=()
  local word_index
  read -r -a string_words <<< "$(printf '%s ' "$@" | tr -d "\"'" | tr ';&|(){}' '      ')"
  for ((word_index = 0; word_index < ${#string_words[@]}; word_index++)); do
    [ "$(basename -- "${string_words[word_index]}")" = "git" ] || continue
    is_commit_subcommand "${string_words[@]:word_index+1}" && return 0
  done
  return 1
}

# is_expanded_word <word>: true when the word holds a parameter expansion or a
# command substitution, whose value the scan never computes.
is_expanded_word() {
  case "$1" in *'$'* | *'`'*) return 0 ;; esac
  return 1
}

# strip_command_prefixes <word>...: prints, one per line, the words left once
# shell keywords and command wrappers (env, time, nice, nohup, sudo, exec,
# command, builtin, timeout, xargs) and their options, assignments, and
# durations are removed from the front, so `env A=1 time git commit` reads as
# the `git commit` it runs.
strip_command_prefixes() {
  local wrapper="" is_duration_pending=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      if | then | else | elif | do | while | until | '!' | '{' | '}' | time | nohup | exec | command | builtin)
        wrapper=""; shift; continue ;;
      env | nice | sudo | xargs) wrapper="$1"; shift; continue ;;
      timeout) wrapper="timeout"; is_duration_pending=1; shift; continue ;;
    esac
    if [ -n "$wrapper" ]; then
      case "$wrapper:$1" in
        env:-u | env:-C | env:-S | nice:-n | sudo:-u | sudo:-g | sudo:-h | sudo:-p | sudo:-C | sudo:-D | sudo:-r | sudo:-t | sudo:-U | timeout:-s | timeout:-k | xargs:-n | xargs:-s | xargs:-I | xargs:-L | xargs:-P | xargs:-d | xargs:-E)
          shift 2 2>/dev/null || shift; continue ;;
      esac
      case "$1" in -* | [A-Za-z_]*=*) shift; continue ;; esac
      if [ "$is_duration_pending" -eq 1 ]; then is_duration_pending=0; shift; continue; fi
    fi
    break
  done
  [ "$#" -gt 0 ] && printf '%s\n' "$@"
  return 0
}

# record_git_commit_directory <directory> <word>...: when the words run
# `git ... commit`, appends the repository it commits to (after -C,
# --work-tree, and a --git-dir naming <repo>/.git) to COMMIT_DIRECTORIES.
record_git_commit_directory() {
  local directory="$1" work_tree="" git_dir="" has_expanded_directory=0 is_absolute_target=0 option_value
  shift
  [ "$(basename -- "${1:-}")" = "git" ] || return 0
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C | --work-tree | --git-dir) option_value="${2:-}" ;;
      -C?*) option_value="${1#-C}" ;;
      --work-tree=* | --git-dir=*) option_value="${1#*=}" ;;
      *) option_value="" ;;
    esac
    if [ -n "$option_value" ]; then
      is_expanded_word "$option_value" && has_expanded_directory=1
      case "$option_value" in /* | "~" | "~"/*) is_absolute_target=1 ;; esac
    fi
    case "$1" in
      -C) directory=$(resolve_relative_directory "$directory" "${2:-}"); shift 2 2>/dev/null || shift ;;
      -C?*) directory=$(resolve_relative_directory "$directory" "${1#-C}"); shift ;;
      --work-tree) work_tree="${2:-}"; shift 2 2>/dev/null || shift ;;
      --work-tree=*) work_tree="${1#--work-tree=}"; shift ;;
      --git-dir) git_dir="${2:-}"; shift 2 2>/dev/null || shift ;;
      --git-dir=*) git_dir="${1#--git-dir=}"; shift ;;
      -c | --namespace | --super-prefix | --config-env) shift 2 2>/dev/null || shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "commit" ] || return 0
  if [ "$has_expanded_directory" -eq 1 ] || { [ "$IS_DIRECTORY_UNKNOWN" -eq 1 ] && [ "$is_absolute_target" -eq 0 ]; }; then
    IS_COMMIT_UNREADABLE=1
    return 0
  fi
  if [ -n "$git_dir" ]; then
    git_dir=$(resolve_relative_directory "$directory" "$git_dir")
    case "$git_dir" in
      */.git | */.git/) directory=$(dirname "${git_dir%/}") ;;
      *) if [ -n "$work_tree" ]; then directory=$(resolve_relative_directory "$directory" "$work_tree"); else directory="$git_dir"; fi ;;
    esac
  elif [ -n "$work_tree" ]; then
    directory=$(resolve_relative_directory "$directory" "$work_tree")
  fi
  COMMIT_DIRECTORIES+=("$directory")
}

# replay_directory_change <word>...: replays a cd or pushd onto TARGET_DIR
# through apply_cd, resolves the quoted repo-top idiom
# `cd "$(git rev-parse --show-toplevel)"` itself, and sets
# IS_DIRECTORY_UNKNOWN when the target is `-`, is otherwise built by
# expansion, or does not exist, since a commit after it runs in a
# directory the scan cannot name; a later cd to a literal absolute directory
# makes it known again.
replay_directory_change() {
  local target=""
  while [ "$#" -gt 0 ]; do case "$1" in -?*) shift ;; *) target="$1"; break ;; esac; done
  if [ "$target" = '$(git rev-parse --show-toplevel)' ]; then
    target=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) || { IS_DIRECTORY_UNKNOWN=1; return 0; }
    TARGET_DIR="$target"
    return 0
  fi
  if [ "$target" = "-" ] || is_expanded_word "$target"; then IS_DIRECTORY_UNKNOWN=1; return 0; fi
  target=$(resolve_relative_directory "$TARGET_DIR" "${target:-~}")
  if [ -d "$target" ]; then
    apply_cd "$target"
    case "$1" in /* | "~" | "~"/*) IS_DIRECTORY_UNKNOWN=0 ;; esac
  else
    IS_DIRECTORY_UNKNOWN=1
  fi
  return 0
}

# inspect_commit_words <word>...: replays a cd or pushd onto TARGET_DIR,
# flags a shell string or eval that mentions git and commit as unreadable,
# and otherwise records a git commit's repository.
inspect_commit_words() {
  local -a command_words=()
  while [ "$#" -gt 0 ] && [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done
  [ "$#" -gt 0 ] || return 0
  case "$1" in cd | pushd) shift; replay_directory_change "$@"; return 0 ;; esac
  while IFS= read -r stripped_word; do command_words+=("$stripped_word"); done < <(strip_command_prefixes "$@")
  [ "${#command_words[@]}" -gt 0 ] || return 0
  case "$(basename -- "${command_words[0]}")" in
    sh | bash | zsh | dash | ksh | eval)
      has_git_commit_in_string "${command_words[@]:1}" && IS_COMMIT_UNREADABLE=1
      return 0 ;;
  esac
  if is_expanded_word "${command_words[0]}"; then
    is_commit_subcommand "${command_words[@]:1}" && IS_COMMIT_UNREADABLE=1
    return 0
  fi
  record_git_commit_directory "$TARGET_DIR" "${command_words[@]}"
}

# collect_commit_directories <command>: fills COMMIT_DIRECTORIES with the
# repository of every git commit the command runs, following cds from the
# session directory, and sets IS_COMMIT_UNREADABLE when a commit sits inside
# a shell string the scan cannot read.
collect_commit_directories() {
  local token is_heredoc_next=0
  local -a words=()
  COMMIT_DIRECTORIES=()
  IS_COMMIT_UNREADABLE=0
  IS_DIRECTORY_UNKNOWN=0
  TARGET_DIR="$CWD"
  scan_command_tokens "$1"
  for token in ${TOKENS[@]+"${TOKENS[@]}"} "$SEPARATOR_TOKEN"; do
    if [ "$is_heredoc_next" -eq 1 ]; then is_heredoc_next=0; continue; fi
    case "$token" in
      "$HEREDOC_TOKEN") is_heredoc_next=1 ;;
      "$SEPARATOR_TOKEN") [ "${#words[@]}" -gt 0 ] && inspect_commit_words "${words[@]}"; words=() ;;
      *) words+=("$token") ;;
    esac
  done
}

# read_ledger_problem <top> <branch>: prints why the ledger does not carry the
# ticket for this branch, or nothing when it does.
read_ledger_problem() {
  local top="$1" branch="$2" ledger="$1/.claude/task-tier.json" ledger_branch
  [ -f "$ledger" ] || { echo "no task-start ledger (.claude/task-tier.json) is recorded in this checkout"; return 0; }
  if git -C "$top" ls-files --error-unmatch .claude/task-tier.json >/dev/null 2>&1; then
    echo "the ledger .claude/task-tier.json is tracked or staged in git, so it is not this session's task-start state (unstage it with \`git rm --cached .claude/task-tier.json\` and add that path to .gitignore)"
    return 0
  fi
  jq -e 'type == "object"' "$ledger" >/dev/null 2>&1 || { echo "the ledger .claude/task-tier.json is unreadable (not the JSON task-tier.sh writes)"; return 0; }
  ledger_branch=$(jq -r '.branch // "" | strings' "$ledger")
  [ "$ledger_branch" = "$branch" ] || { echo "the ledger records branch '${ledger_branch}', not '${branch}', so it belongs to another task (the ledger is one file per checkout: keep one worktree per in-flight ticket, or re-record this branch's own ticket before working on it)"; return 0; }
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
    COMMAND_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
    case "$COMMAND_TEXT" in *commit*) ;; *) exit 0 ;; esac
    for helper in shell-command-scan.sh; do
      # shellcheck source=/dev/null
      [ -f "$HOOK_DIR/$helper" ] && source "$HOOK_DIR/$helper"
    done
    type scan_command_tokens >/dev/null 2>&1 && type apply_cd >/dev/null 2>&1 ||
      deny "R-605 (ticket at task start): the shell scan helpers (shell-command-scan.sh, shell-command-tokens.sh) are missing, so this command's commits cannot be read; re-run ./sync.sh."
    collect_commit_directories "$COMMAND_TEXT"
    [ "$IS_COMMIT_UNREADABLE" -eq 0 ] ||
      deny "R-605 (ticket at task start): this command runs git commit inside a shell string (sh -c, bash -c, eval), through a command word built by expansion, or in a directory the hook cannot name (a cd or git -C target built from \$VAR, \$(...), or \`cd -\`, or one that does not exist), so it cannot check the ticket. Run the commit as a plain \`git commit\` (or \`git -C <repo> commit\`) of its own."
    ACTION="committing" ;;
  *) exit 0 ;;
esac

# judge_work_directory <directory>: denies when the directory sits in a git
# work tree on a branch whose ledger does not carry the ticket.
judge_work_directory() {
  local top branch problem
  [ -n "$1" ] || return 0
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(cd "$top" && pwd -P)
  if [ "$TOOL" != "Bash" ] && is_exempt_edit_path "$top" "$FILE_PATH"; then return 0; fi
  branch=$(git -C "$top" branch --show-current 2>/dev/null)
  [ -n "$branch" ] || return 0
  problem=$(read_ledger_problem "$top" "$branch")
  [ -z "$problem" ] && return 0
  deny_without_ticket "$branch" "$problem"
}

# deny_without_ticket <branch> <problem>: the R-605 deny naming what is missing
# and how to record it.
deny_without_ticket() {
  local branch="$1" problem="$2"
  deny "R-605 (ticket at task start): $ACTION on branch '$branch' is refused because $problem. The ticket comes before the work: open it with /ticket-lifecycle, then record it on this branch with \`bash ~/.claude/skills/task-start/scripts/task-tier.sh set <tier> \"<reason>\" --ticket <KEY>\` (a trivial task records \`task-tier.sh set trivial \"<reason>\"\` and needs no ticket). When the work already happened without a ticket, open it retroactively with its actuals and then record it."
}

if [ "$TOOL" = "Bash" ]; then
  for commit_directory in ${COMMIT_DIRECTORIES[@]+"${COMMIT_DIRECTORIES[@]}"}; do judge_work_directory "$commit_directory"; done
else
  judge_work_directory "$WORK_DIRECTORY"
fi
exit 0
