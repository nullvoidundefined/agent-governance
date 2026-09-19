#!/usr/bin/env bash
# draft-pr-on-first-push.sh: PostToolUse Bash hook (R-517). When a Bash call
# really ran `git push` for the checked-out branch, the push succeeded, the
# branch is not the default branch (nor main, master, or staging), and GitHub
# has no open pull request whose head is that branch, the hook opens a DRAFT
# pull request itself with `gh pr create --draft`, then tells the session to
# turn on the desktop app's PR monitor for it (pr-monitor-instruction.sh).
#
# Title: the subject of the oldest commit in base..HEAD. Body: the commit
# subjects in the range, each distinct `Refs: <KEY>` line from the range's
# commit messages, and the Claude Code attribution line. Base: the default
# branch (the remote's HEAD, else `gh repo view`).
#
# R-605 still applies, through the same checks the PreToolUse gate
# pr-ticket-ref-gate.sh uses (pr-range-checks.sh): a range with no Refs line
# that is neither docs-only nor trivial tier opens nothing and tells the
# session to open a ticket, add the trailer, and push again; with
# ~/.claude/TICKET-TRACKER.json absent the draft opens on R-605's degraded
# path with a warning. The gate itself never sees this hook's gh call, which
# is why the check is repeated here rather than left to it.
#
# What is not a push of a branch: a quoted "git push" inside another command
# (the command is read as shell words by shell-command-scan.sh), --dry-run or
# -n, --delete or a `:branch` refspec, a tag-only push (--tags, or refspecs
# naming only tags), --all, --mirror, a push naming a branch other than the
# checked-out one, and a push to a URL rather than a named remote. Success is
# read from the tool response (not interrupted, no rejection on stderr) and
# confirmed from git state: the remote-tracking ref for the pushed branch must
# equal HEAD.
#
# Opt-out: `"autoDraftPr": false` in .enforce.json at the repository root.
#
# This runs after the push and must never fail it: every error (no gh, gh
# unauthenticated, no resolvable default branch, a network failure, a gh call
# outliving CLAUDE_GH_TIMEOUT_SECONDS, default 15) is logged through
# log-rule-fire.sh and ends in exit 0 with at most a one-line note. CLAUDE_GH_CMD
# replaces gh, as it does for git-workflow-guard.sh.
set -uo pipefail

PREFILTER_PATTERN='git[[:space:]].*push'
PR_URL_PATTERN='https?://[^[:space:]]+/pull/[0-9]+'
PUSH_FAILURE_PATTERN='error: failed to push|! \[rejected\]|! \[remote rejected\]|^fatal:'
REDIRECTION_PATTERN='^[0-9]*(<|>|>>|>\|)(.*)$'
MAX_LISTED_COMMITS=20
ATTRIBUTION_LINE='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"
GH_TIMEOUT_SECONDS="${CLAUDE_GH_TIMEOUT_SECONDS:-15}"
[[ "$GH_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || GH_TIMEOUT_SECONDS=15

# record_fire <decision>: logs one R-517 fire through the telemetry helper.
record_fire() {
  local helper="$HOOK_DIR/log-rule-fire.sh"
  # shellcheck source=log-rule-fire.sh
  [ -f "$helper" ] && source "$helper"
  type log_rule_fire >/dev/null 2>&1 && log_rule_fire "R-517" "draft-pr-on-first-push" "$1"
  return 0
}

# emit_context <message>: hands the session one PostToolUse context message.
emit_context() {
  jq -nc --arg m "$1" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
}

# give_up_with_note <reason>: logs an error fire, emits the one-line note,
# and ends the hook without touching the push.
give_up_with_note() {
  record_fire "error"
  emit_context "R-517 (draft PR): no draft pull request was opened for ${PUSHED_BRANCH:-this branch}: $1. Open one with \`gh pr create --draft\` if it is wanted."
  exit 0
}

# resolve_directory <base> <path>: prints path resolved against base.
resolve_directory() {
  case "$2" in
    "~") printf '%s' "$HOME" ;;
    "~"/*) printf '%s' "$HOME/${2#\~/}" ;;
    /*) printf '%s' "$2" ;;
    *) printf '%s' "$1/$2" ;;
  esac
}

# is_git_push_command <stdin> <word>...: a find_simple_command matcher for
# `git [global options] push`; records the repository directory in PUSH_DIR
# and the push's own arguments in PUSH_ARGS. --git-dir and --work-tree point
# at a repository this hook cannot model reliably, so they are not matched.
is_git_push_command() {
  shift
  [ "${1:-}" = "git" ] || return 1
  shift
  PUSH_DIR="$TARGET_DIR"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) PUSH_DIR=$(resolve_directory "$PUSH_DIR" "${2:-}"); shift 2 || return 1 ;;
      --git-dir|--git-dir=*|--work-tree|--work-tree=*) return 1 ;;
      -c|--namespace|--super-prefix|--config-env) shift 2 || return 1 ;;
      -*) shift ;;
      push) shift; PUSH_ARGS=("$@"); return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# parse_push_arguments: splits PUSH_ARGS into PUSH_REMOTE and PUSH_REFSPECS;
# returns 1 for a push that is not a push of a branch (dry run, delete, tags
# only, all, mirror).
parse_push_arguments() {
  local arg is_value_next=0 is_remote_next=0 is_tags=0
  PUSH_REMOTE=''; PUSH_REFSPECS=()
  for arg in ${PUSH_ARGS[@]+"${PUSH_ARGS[@]}"}; do
    if [ "$is_value_next" -eq 1 ]; then is_value_next=0; continue; fi
    if [ "$is_remote_next" -eq 1 ]; then PUSH_REMOTE="$arg"; is_remote_next=0; continue; fi
    # A redirection is the shell's, not a push argument: `2>` (the scanner
    # ends the command at the & of 2>&1), `>/dev/null`, or `>` then a target.
    if [[ "$arg" =~ $REDIRECTION_PATTERN ]]; then
      [ -z "${BASH_REMATCH[2]}" ] && is_value_next=1
      continue
    fi
    case "$arg" in
      --dry-run|--delete|--all|--branches|--mirror|--prune) return 1 ;;
      --tags) is_tags=1 ;;
      -o|--push-option|--receive-pack|--exec) is_value_next=1 ;;
      --repo) is_remote_next=1 ;;
      --repo=*) PUSH_REMOTE="${arg#--repo=}" ;;
      --) ;;
      --*) ;;
      -*) [[ "$arg" =~ [nd] ]] && return 1 ;;
      *) if [ -z "$PUSH_REMOTE" ]; then PUSH_REMOTE="$arg"; else PUSH_REFSPECS+=("$arg"); fi ;;
    esac
  done
  [ "$is_tags" -eq 1 ] && [ "${#PUSH_REFSPECS[@]}" -eq 0 ] && return 1
  return 0
}

# is_tag_name <dir> <name>: true when name is a tag and not a branch.
is_tag_name() {
  case "$2" in refs/tags/*) return 0 ;; refs/heads/*) return 1 ;; esac
  git -C "$1" show-ref --verify -q "refs/heads/$2" && return 1
  git -C "$1" show-ref --verify -q "refs/tags/$2"
}

# resolve_pushed_branch <dir> <current-branch>: sets PUSHED_BRANCH to the
# remote branch name the push wrote for the checked-out branch; returns 1
# when the push deletes a branch or never pushes the checked-out one.
resolve_pushed_branch() {
  local dir="$1" current="$2" spec source destination
  PUSHED_BRANCH=''
  if [ "${#PUSH_REFSPECS[@]}" -eq 0 ]; then PUSHED_BRANCH="$current"; return 0; fi
  for spec in "${PUSH_REFSPECS[@]}"; do
    spec="${spec#+}"
    case "$spec" in :*) return 1 ;; esac
    source="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then destination="${spec#*:}"; else destination="$source"; fi
    is_tag_name "$dir" "$source" && continue
    source="${source#refs/heads/}"
    [ "$destination" = "@" ] && destination="HEAD"
    [ "$source" = "@" ] && source="HEAD"
    [ "$source" = "HEAD" ] && source="$current" && [ "$destination" = "HEAD" ] && destination="$current"
    [ "$source" = "$current" ] || continue
    PUSHED_BRANCH="${destination#refs/heads/}"
    return 0
  done
  return 1
}

# resolve_push_remote <dir> <current-branch>: prints the named remote the
# push went to, following git's own order when the command named none.
resolve_push_remote() {
  local dir="$1" current="$2" remote="$PUSH_REMOTE"
  [ -n "$remote" ] || remote=$(git -C "$dir" config "branch.$current.pushRemote" 2>/dev/null || true)
  [ -n "$remote" ] || remote=$(git -C "$dir" config remote.pushDefault 2>/dev/null || true)
  [ -n "$remote" ] || remote=$(git -C "$dir" config "branch.$current.remote" 2>/dev/null || true)
  printf '%s' "${remote:-origin}"
}

# is_push_successful <dir> <remote>: true when the tool response shows no
# interruption or rejection and the remote-tracking ref for the pushed branch
# now equals HEAD.
is_push_successful() {
  local dir="$1" remote="$2" tracking head
  jq -e '.tool_response.interrupted == true' >/dev/null 2>&1 <<< "$INPUT" && return 1
  jq -e '(.tool_response.exit_code // .tool_response.exitCode // 0) != 0' >/dev/null 2>&1 <<< "$INPUT" && return 1
  grep -Eq -- "$PUSH_FAILURE_PATTERN" <<< "$(jq -r '.tool_response.stderr // "" | strings' 2>/dev/null <<< "$INPUT")" && return 1
  tracking=$(git -C "$dir" rev-parse -q --verify "refs/remotes/$remote/$PUSHED_BRANCH" 2>/dev/null) || return 1
  head=$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null) || return 1
  [ "$tracking" = "$head" ]
}

# is_opted_out <repo-top>: true when .enforce.json sets autoDraftPr to false.
is_opted_out() {
  [ -f "$1/.enforce.json" ] && jq -e '.autoDraftPr == false' "$1/.enforce.json" >/dev/null 2>&1
}

# run_gh <output-file> <arg>...: runs gh from TOP with its stdout in the
# file; returns gh's status, or 124 when it outlives the deadline. Polls in
# 0.2s steps, as git-workflow-guard.sh does, rather than leaving an orphaned
# `sleep N` watchdog behind.
run_gh() {
  local output_file="$1" gh_command="${CLAUDE_GH_CMD:-gh}" deadline_steps waited_steps=0 gh_pid
  shift
  deadline_steps=$(( $GH_TIMEOUT_SECONDS * 5 ))
  (cd "$TOP" && exec "$gh_command" "$@") >"$output_file" 2>/dev/null </dev/null &
  gh_pid=$!
  while kill -0 "$gh_pid" 2>/dev/null; do
    if [ "$waited_steps" -ge "$deadline_steps" ]; then
      kill -KILL "$gh_pid" 2>/dev/null
      wait "$gh_pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
    waited_steps=$((waited_steps + 1))
  done
  wait "$gh_pid"
}

# describe_gh_failure <status>: the note's reason for a failed gh call.
describe_gh_failure() {
  if [ "$1" -eq 124 ]; then printf 'gh %s did not answer within %ss' "$2" "$GH_TIMEOUT_SECONDS"
  else printf 'gh %s failed (exit %s; unauthenticated, offline, or not a GitHub remote)' "$2" "$1"; fi
}

# resolve_default_branch <remote>: prints the default branch name from the
# remote's HEAD ref, else from gh repo view.
resolve_default_branch() {
  local remote="$1" name
  name=$(git -C "$TOP" symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$name" ]; then printf '%s' "${name#"$remote"/}"; return 0; fi
  run_gh "$SCRATCH/default" repo view --json defaultBranchRef --jq '.defaultBranchRef.name' || return
  tr -d '[:space:]' < "$SCRATCH/default"
}

# find_open_pr_url: prints the URL of the open PR headed by PUSHED_BRANCH,
# empty when there is none; returns gh's status on failure.
find_open_pr_url() {
  local status
  run_gh "$SCRATCH/existing" pr list --head "$PUSHED_BRANCH" --state open --json url --jq '.[0].url // ""'
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  tr -d '[:space:]' < "$SCRATCH/existing"
}

# write_pr_body <base> <file>: the draft's body, commit subjects then the
# distinct Refs lines then the attribution line.
write_pr_body() {
  local base="$1" file="$2" count refs
  count=$(git -C "$TOP" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)
  refs=$(git -C "$TOP" log --reverse --format=%B "$base..HEAD" 2>/dev/null \
    | grep -E -- "$REFS_LINE_PATTERN" | grep -Eo -- "Refs:[[:space:]]*$KEY_PATTERN" \
    | sed -E 's/^Refs:[[:space:]]*/Refs: /' | awk '!seen[$0]++' || true)
  {
    printf '## Commits\n\n'
    git -C "$TOP" log --reverse --format='- %s' "$base..HEAD" 2>/dev/null | head -n "$MAX_LISTED_COMMITS"
    [ "$count" -gt "$MAX_LISTED_COMMITS" ] && printf -- '- ...and %s more\n' "$((count - MAX_LISTED_COMMITS))"
    [ -n "$refs" ] && printf '\n%s\n' "$refs"
    printf '\n%s\n' "$ATTRIBUTION_LINE"
  } > "$file"
}

# is_ticket_requirement_met <base>: R-605 through the shared checks: a Refs
# line in the range, a docs-only range, or a trivial tier for the branch.
is_ticket_requirement_met() {
  commits_have_reference "$TOP" "$1" || is_docs_only_range "$TOP" "$1" || is_trivial_tier "$TOP"
}

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // "" | strings' 2>/dev/null <<< "$INPUT" || true)
grep -Eq -- "$PREFILTER_PATTERN" <<< "$CMD" || exit 0
for helper in shell-command-scan.sh pr-range-checks.sh pr-monitor-instruction.sh; do
  [ -f "$HOOK_DIR/$helper" ] || { record_fire "error"; exit 0; }
  # shellcheck source=/dev/null
  source "$HOOK_DIR/$helper"
done

SESSION_DIR=$(jq -r '.cwd // "" | strings' 2>/dev/null <<< "$INPUT" || true)
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || SESSION_DIR="$PWD"
scan_command_tokens "$CMD"
find_simple_command "$SESSION_DIR" is_git_push_command || exit 0
parse_push_arguments || exit 0
TOP=$(git -C "$PUSH_DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$TOP" ] || exit 0
CURRENT_BRANCH=$(git -C "$TOP" branch --show-current 2>/dev/null || true)
[ -n "$CURRENT_BRANCH" ] || exit 0
resolve_pushed_branch "$TOP" "$CURRENT_BRANCH" || exit 0
REMOTE=$(resolve_push_remote "$TOP" "$CURRENT_BRANCH")
git -C "$TOP" remote get-url "$REMOTE" >/dev/null 2>&1 || exit 0
is_push_successful "$TOP" "$REMOTE" || exit 0
case "$PUSHED_BRANCH" in main|master|staging) exit 0 ;; esac
is_opted_out "$TOP" && exit 0

SCRATCH=$(mktemp -d 2>/dev/null) || give_up_with_note "no temporary directory could be created"
trap 'rm -rf "$SCRATCH"' EXIT
command -v "${CLAUDE_GH_CMD:-gh}" >/dev/null 2>&1 || give_up_with_note "the gh CLI is not installed"
DEFAULT_BRANCH=$(resolve_default_branch "$REMOTE") || give_up_with_note "$(describe_gh_failure $? 'repo view')"
[ -n "$DEFAULT_BRANCH" ] || give_up_with_note "the repository's default branch could not be resolved"
[ "$PUSHED_BRANCH" = "$DEFAULT_BRANCH" ] && exit 0

EXISTING_URL=$(find_open_pr_url) || give_up_with_note "$(describe_gh_failure $? 'pr list')"
[ -n "$EXISTING_URL" ] && exit 0

BASE=$(resolve_pr_base "$DEFAULT_BRANCH" "$TOP")
[ -n "$BASE" ] || give_up_with_note "no merge base with $DEFAULT_BRANCH could be found"
TITLE=$(git -C "$TOP" log --reverse --format=%s "$BASE..HEAD" 2>/dev/null | head -1)
[ -n "$TITLE" ] || exit 0

DEGRADED_NOTE=''
if ! is_ticket_requirement_met "$BASE"; then
  if [ -f "$HOME/.claude/TICKET-TRACKER.json" ]; then
    record_fire "ticket-missing"
    emit_context "R-517 (draft PR) with R-605 (ticket reference): no draft pull request was opened for $PUSHED_BRANCH, because no commit in $DEFAULT_BRANCH..$PUSHED_BRANCH carries a \`Refs: <KEY>\` line and the range is neither docs-only nor trivial tier. Open the ticket with /ticket-lifecycle, add \`Refs: <KEY>\` as a commit trailer, and push again; the draft opens on that push."
    exit 0
  fi
  DEGRADED_NOTE=" R-605's degraded path applies: the range carries no \`Refs: <KEY>\` line and no tracker is configured (~/.claude/TICKET-TRACKER.json is absent), so record the ticket field set (title, tier, assist, model, estimate, repo, branch) in docs/session-handoff/session-handoff.md."
fi

write_pr_body "$BASE" "$SCRATCH/body.md"
run_gh "$SCRATCH/created" pr create --draft --base "$DEFAULT_BRANCH" --head "$PUSHED_BRANCH" --title "$TITLE" --body-file "$SCRATCH/body.md"
CREATE_STATUS=$?
[ "$CREATE_STATUS" -eq 0 ] || give_up_with_note "$(describe_gh_failure "$CREATE_STATUS" 'pr create')"
PR_URL=$(grep -Eo -- "$PR_URL_PATTERN" "$SCRATCH/created" | tail -1 || true)
[ -n "$PR_URL" ] || give_up_with_note "gh pr create printed no pull request URL"

if [ -n "$DEGRADED_NOTE" ]; then record_fire "degraded"; else record_fire "opened"; fi
emit_context "R-517 (draft PR): opened draft pull request $PR_URL for $PUSHED_BRANCH against $DEFAULT_BRANCH. Write the docs/prs/ document and finish review before marking it ready with \`gh pr ready\`.${DEGRADED_NOTE} $(print_monitor_instruction "$PR_URL")"
exit 0
