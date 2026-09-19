#!/usr/bin/env bash
# git-workflow-guard.sh: the R-5xx rules that are decidable from a git or gh
# command plus the index. One PreToolUse(Bash) hook, five rules:
#   R-514  a push whose target branch is main/master asks first, and so does
#          `gh pr merge` (authorization is per turn, never standing)
#   R-512  `gh pr merge --merge` (`-m`) is denied, and so is `--rebase` (`-r`)
#          unless the PR is a bundle (the `bundle` label, a distinct `Refs:`
#          trailer on every commit, read from `gh pr view`); feature branches
#          squash-merge into one commit per feature
#   R-517  `gh pr merge` is denied unless the PR body, read from `gh pr view`,
#          carries a Markdown heading named "Codex review" with at least one
#          non-blank line under it (the blocking pre-merge Codex review)
#   R-511  advisory: a cross-cutting change (5+ files, 3+ directories) landing
#          directly on main wants its own branch
#   R-508  advisory: a commit that adds a user-facing surface or changes setup
#          and touches no README
#
# The global repo is exempt from the two main-branch rules: main IS its
# working branch, and its pushes are already gated by global-repo-push-guard
# for R-106. Recognition is delegated to repo-identity.sh (origin remote
# URL, or the legacy ~/.claude toplevel); when the helper cannot be
# sourced the repo is treated as non-exempt, which fails toward asking.
# Advisories print to stderr and never block.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
# A backslash-newline is a line continuation: join it first, so a command
# split across lines (`gh pr \<newline> merge 42`) reads as the one command
# the shell runs. An escaped backslash before the newline (`echo x\\`) is a
# literal backslash and ends the line, so it is set aside before the join and
# restored after it.
LINE_CONTINUATION=$'\\\n'
ESCAPED_BACKSLASH_NEWLINE=$'\\\\\n'
ESCAPED_BACKSLASH_MARK=$'\\\\\001'
CMD="${CMD//"$ESCAPED_BACKSLASH_NEWLINE"/$ESCAPED_BACKSLASH_MARK}"
CMD="${CMD//"$LINE_CONTINUATION"/ }"
CMD="${CMD//$'\001'/$'\n'}"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"

# `git -C <path> push` and `git --no-pager commit` are the same actions with a
# global option in front, and matching on adjacency alone lets them through.
# Strip the whole option class via git-invocation.sh (2026-09-16 audit P2-1),
# and let the repository-selecting options redirect the repository the rest of
# this hook inspects.
#
# The redirect used to be a regex that read `-C` alone, from the first git
# invocation in the command, with an unquoted path. `--work-tree`, a quoted
# path, and a `git -C /a fetch && git -C /b push` pairing all slipped past it
# and left the hook judging the ambient repository (2026-09-18 audit, defect
# 4). The shared parser in git-invocation.sh covers all of those shapes, so
# the extraction here is now one call against the UNSTRIPPED command.
# -f guard, not `source ... || true`: a failed source aborts the shell under
# set -e regardless of the || (observed 2026-09-16), a silent fail-open.
RAW_CMD="$CMD"
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  GIT_DIRECTORY=""
  for subcommand in push commit; do
    parse_git_target_options "$RAW_CMD" "$subcommand"
    GIT_DIRECTORY=$(read_git_target_directory)
    [ -n "$GIT_DIRECTORY" ] && break
  done
else
  # Fallback keeps the pre-helper coverage rather than none.
  CMD=$(printf '%s' "$CMD" | sed -E 's/git([[:space:]]+(-C|-c)[[:space:]]+[^[:space:];&|]+)+/git/g')
  GIT_DIRECTORY=$(printf '%s' "$RAW_CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' | head -1 | awk '{print $3}' || true)
fi
if [ -n "$GIT_DIRECTORY" ]; then
  case "$GIT_DIRECTORY" in /*) CWD="$GIT_DIRECTORY" ;; *) CWD="$CWD/$GIT_DIRECTORY" ;; esac
fi

# A `gh pr merge` may follow leading environment assignments
# (`GH_REPO=o/r gh pr merge ...`), which run the same merge.
GH_MERGE_PATTERN='(^|[;&|])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
# Whether a command runs a merge at all is decided by a quote-aware shell scan
# (shell-command-tokens.sh), never by a regex over the raw text: a regex
# missed merges hidden by braces, subshells, control flow, quoting, and
# escapes, and read merges into quoted commit messages and heredocs. The scan
# runs only when a copy of the command with quotes and backslashes removed
# mentions both gh and merge, so ordinary commands pay nothing for it. A
# missing helper is treated as a merge the hook cannot read, which denies.
SHELL_TOKENS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-tokens.sh"
IS_SHELL_TOKENS_LOADED=0
if [ -f "$SHELL_TOKENS_HELPER" ]; then
  # shellcheck source=shell-command-tokens.sh
  source "$SHELL_TOKENS_HELPER" && IS_SHELL_TOKENS_LOADED=1
fi
UNQUOTED_CMD="${CMD//[\"\'\\]/}"
IS_MERGE_CANDIDATE=0
[[ "$UNQUOTED_CMD" == *gh* && "$UNQUOTED_CMD" == *merge* ]] && IS_MERGE_CANDIDATE=1
grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+(push|commit)([[:space:]]|$)' <<< "$CMD" ||
  [ "$IS_MERGE_CANDIDATE" -eq 1 ] || exit 0

ask() {
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$1" | grep -oE 'R-[0-9]{3}' | head -1)" "git-workflow-guard" "ask"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

deny() {
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$1" | grep -oE 'R-[0-9]{3}' | head -1)" "git-workflow-guard" "deny"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# parse_merge_arguments: reads the `gh pr merge` arguments in $CMD and sets
# MERGE_HAS_MERGE_FLAG and MERGE_HAS_REBASE_FLAG (long, short, and bundled
# short forms such as `-dr`) plus MERGE_VIEW_ARGUMENTS, the `gh pr view`
# arguments naming the same PR: the first positional argument (a number, URL,
# or branch) and any --repo/-R. The values of merge's value-taking flags are
# skipped so a subject or head SHA is never mistaken for the PR or a strategy.
# Word splitting is on whitespace only, so a quoted value holding a space can
# at worst read as an extra strategy flag or the wrong PR, and both of those
# end in a deny.
parse_merge_arguments() {
  local merge_arguments merge_token short_flags short_flag skip_next=0 repo_next=0 pr_selector=""
  MERGE_HAS_MERGE_FLAG=0
  MERGE_HAS_REBASE_FLAG=0
  MERGE_VIEW_ARGUMENTS=()
  merge_arguments=$(printf '%s' "$CMD" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[^;&|]*' | head -1 |
    sed -E 's/^gh[[:space:]]+pr[[:space:]]+merge[[:space:]]*//' || true)
  local -a merge_tokens=()
  read -r -a merge_tokens <<< "$merge_arguments"
  for merge_token in ${merge_tokens[@]+"${merge_tokens[@]}"}; do
    if [ "$repo_next" -eq 1 ]; then MERGE_VIEW_ARGUMENTS+=(--repo "$merge_token"); repo_next=0; continue; fi
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$merge_token" in
      --merge | --merge=*) MERGE_HAS_MERGE_FLAG=1 ;;
      --rebase | --rebase=*) MERGE_HAS_REBASE_FLAG=1 ;;
      --repo) repo_next=1 ;;
      --repo=*) MERGE_VIEW_ARGUMENTS+=("$merge_token") ;;
      --subject | --body | --body-file | --author-email | --match-head-commit) skip_next=1 ;;
      --*) ;;
      -?*)
        short_flags="${merge_token#-}"
        while [ -n "$short_flags" ]; do
          short_flag="${short_flags:0:1}"
          short_flags="${short_flags:1}"
          case "$short_flag" in
            m) MERGE_HAS_MERGE_FLAG=1 ;;
            r) MERGE_HAS_REBASE_FLAG=1 ;;
            R) if [ -n "$short_flags" ]; then MERGE_VIEW_ARGUMENTS+=(--repo "$short_flags"); else repo_next=1; fi; break ;;
            t | b | F | A) [ -z "$short_flags" ] && skip_next=1; break ;;
          esac
        done ;;
      *) [ -z "$pr_selector" ] && pr_selector="$merge_token" ;;
    esac
  done
  [ -n "$pr_selector" ] && MERGE_VIEW_ARGUMENTS=("$pr_selector" ${MERGE_VIEW_ARGUMENTS[@]+"${MERGE_VIEW_ARGUMENTS[@]}"})
  return 0
}

# run_gh_view_with_deadline: runs `gh pr view` for the merge's PR from $CWD,
# asking for the labels, commits, and body, and prints its output, returning non-zero when gh fails or outlives
# CLAUDE_GH_TIMEOUT_SECONDS (default 15). The deadline keeps the guard
# fail-closed: a hook killed by the harness timeout prints nothing, and an
# empty PreToolUse output is an allow. Polls in 0.2s steps rather than using a
# `sleep N` watchdog, for the orphaned-sleep reason verification-gate.sh
# records beside its run_with_timeout.
run_gh_view_with_deadline() {
  local gh_command="${CLAUDE_GH_CMD:-gh}" deadline_steps waited_steps=0 view_output_file gh_pid gh_status
  deadline_steps=$(( ${CLAUDE_GH_TIMEOUT_SECONDS:-15} * 5 ))
  view_output_file=$(mktemp) || return 1
  (cd "$CWD" && exec "$gh_command" pr view ${MERGE_VIEW_ARGUMENTS[@]+"${MERGE_VIEW_ARGUMENTS[@]}"} --json labels,commits,body) >"$view_output_file" 2>/dev/null &
  gh_pid=$!
  while kill -0 "$gh_pid" 2>/dev/null; do
    if [ "$waited_steps" -ge "$deadline_steps" ]; then
      kill -KILL "$gh_pid" 2>/dev/null
      wait "$gh_pid" 2>/dev/null
      rm -f "$view_output_file"
      return 124
    fi
    sleep 0.2
    waited_steps=$((waited_steps + 1))
  done
  wait "$gh_pid"
  gh_status=$?
  cat "$view_output_file"
  rm -f "$view_output_file"
  return "$gh_status"
}

# read_merge_pr_view: fetches the merged PR's view once and sets PR_JSON on
# success or PR_VIEW_PROBLEM to the sentence saying why it could not be read.
# A command that changes directory or sets GH_REPO/GH_HOST merges a PR the
# hook's own gh view cannot see, so it is reported as unverifiable, as is a gh
# that errors, hangs, or answers with anything jq cannot read. CLAUDE_GH_CMD
# replaces gh for the fixture.
read_merge_pr_view() {
  PR_JSON=""
  PR_VIEW_PROBLEM=""
  if [ "$HAS_DIRECTORY_CHANGE" -eq 1 ] ||
    grep -qE '(^|[;&|(])[[:space:]]*(cd|pushd)([[:space:]]|$)|(^|[[:space:]])GH_(REPO|HOST)=' <<< "$CMD"; then
    PR_VIEW_PROBLEM="the command changes directory or sets GH_REPO/GH_HOST, so the hook cannot check the PR it merges; run the merge from the repository's own directory with no cd."
    return 0
  fi
  if ! PR_JSON=$(run_gh_view_with_deadline) ||
    ! printf '%s' "$PR_JSON" | jq -e '(.labels | type == "array") and (.commits | type == "array")' >/dev/null 2>&1; then
    PR_JSON=""
    PR_VIEW_PROBLEM="gh pr view could not return the PR's labels, commits, and body, so the PR is unverified."
  fi
  return 0
}

# read_bundle_verdict: prints "ok" when the PR being merged is a bundle PR
# (R-512's exception): it carries the `bundle` label and every commit message
# holds a `Refs: <KEY>` trailer line naming a ticket no other commit names.
# Otherwise prints the sentence naming the first missing condition, or the
# reason read_merge_pr_view could not read the PR.
read_bundle_verdict() {
  local pr_json="$PR_JSON"
  if [ -n "$PR_VIEW_PROBLEM" ]; then
    echo "$PR_VIEW_PROBLEM"
    return 0
  fi
  if ! printf '%s' "$pr_json" | jq -e 'any(.labels[]; .name == "bundle")' >/dev/null 2>&1; then
    echo "the PR has no \`bundle\` label."
    return 0
  fi
  if ! printf '%s' "$pr_json" | jq -e '(.commits | length) > 0 and all(.commits[];
      ((.messageHeadline // "") + "\n" + (.messageBody // "")) | test("(^|\n)Refs: [A-Z][A-Z0-9]+-[0-9]+"))' >/dev/null 2>&1; then
    echo "at least one commit has no \`Refs: <KEY>\` trailer line."
    return 0
  fi
  if ! printf '%s' "$pr_json" | jq -e '[.commits[] | ((.messageHeadline // "") + "\n" + (.messageBody // ""))
      | capture("(^|\n)Refs: (?<key>[A-Z][A-Z0-9]+-[0-9]+)").key] | length == (unique | length)' >/dev/null 2>&1; then
    echo "two or more commits name the same ticket in their \`Refs:\` trailer, which is one ticket's history rather than a bundle."
    return 0
  fi
  echo ok
}

# has_codex_review_section <body>: true when the PR body holds a Markdown
# heading (any level, any case) whose text starts with "Codex review" and at
# least one non-blank line follows it before the next heading. A mention in
# prose is not a section, and a bare heading records no findings. Lines inside
# a fenced code block count as neither heading nor content, so a template that
# quotes the section as an example does not pass for it; a fence closes only
# on a line holding nothing but a run of its own character at least as long
# as the one that opened it. HTML comments are removed the same way (inline
# ones stripped, a multi-line one skipped to its `-->`), after code spans are
# dropped, so a `<!--` quoted in a code span opens nothing.
# A heading is indented by at most three spaces, since four make it an
# indented code block. No regex intervals: older mawk lacks them.
has_codex_review_section() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    in_fence {
      if ($0 ~ /^( |  |   )?(`+|~+)[ \t]*$/) {
        run = $0
        gsub(/[ \t]/, "", run)
        if (substr(run, 1, 1) == substr(fence, 1, 1) && length(run) >= length(fence)) in_fence = 0
      }
      next
    }
    { line = $0 }
    in_comment {
      comment_end = index(line, "-->")
      if (!comment_end) next
      in_comment = 0
      line = substr(line, comment_end + 3)
    }
    line == $0 && line ~ /^( |  |   )?(```|~~~)/ && match(line, /(`+|~+)/) && RLENGTH >= 3 {
      in_fence = 1
      fence = substr(line, RSTART, RLENGTH)
      next
    }
    {
      gsub(/`[^`]*`/, "", line)
      gsub(/<!--([^-]|-[^-]|--[^>])*-->/, "", line)
      comment_start = index(line, "<!--")
      if (comment_start) { in_comment = 1; line = substr(line, 1, comment_start - 1) }
    }
    line ~ /^( |  |   )?#+[ \t]/ {
      heading = tolower(line)
      sub(/^[ \t]*#+[ \t]+/, "", heading)
      in_section = (index(heading, "codex review") == 1)
      next
    }
    in_section && line ~ /[^ \t]/ { found = 1 }
    END { exit found ? 0 : 1 }'
}

# read_codex_review_verdict: prints "ok" when the merged PR's body carries the
# R-517 Codex review section, otherwise the sentence naming what is missing.
read_codex_review_verdict() {
  local pr_body
  if [ -n "$PR_VIEW_PROBLEM" ]; then
    echo "$PR_VIEW_PROBLEM"
    return 0
  fi
  pr_body=$(printf '%s' "$PR_JSON" | jq -r '.body // "" | strings' 2>/dev/null || true)
  if has_codex_review_section "$pr_body"; then
    echo ok
    return 0
  fi
  echo "the PR body has no \`## Codex review\` section with content under it."
}

# classify_merge_commands <command> <is-nested>: walks the command's simple
# commands and, for each that runs `gh pr merge`, adds one to MERGE_TOTAL and,
# when its words are exactly `gh pr merge ...` with no wrapper, keyword,
# path, or option ahead of `merge`, one to MERGE_CANONICAL. It sets
# HAS_DIRECTORY_CHANGE for any cd, pushd, or popd, and scans the string given
# to eval or to bash/sh/zsh -c as a nested command (depth-limited), whose
# merges are never canonical.
classify_merge_commands() {
  local command_text="$1" is_nested="${2:-0}" token is_heredoc_next=0
  local -a command_tokens=() words=()
  [ "${CLASSIFY_DEPTH:-0}" -lt 4 ] || { MERGE_TOTAL=$((MERGE_TOTAL + 1)); return 0; }
  CLASSIFY_DEPTH=$(( ${CLASSIFY_DEPTH:-0} + 1 ))
  scan_command_tokens "$command_text"
  command_tokens=(${TOKENS[@]+"${TOKENS[@]}"})
  for token in ${command_tokens[@]+"${command_tokens[@]}"}; do
    if [ "$is_heredoc_next" -eq 1 ]; then is_heredoc_next=0; continue; fi
    case "$token" in
      "$HEREDOC_TOKEN") is_heredoc_next=1 ;;
      "$SEPARATOR_TOKEN") classify_simple_command "$is_nested" ${words[@]+"${words[@]}"}; words=() ;;
      *) words+=("$token") ;;
    esac
  done
  classify_simple_command "$is_nested" ${words[@]+"${words[@]}"}
  CLASSIFY_DEPTH=$((CLASSIFY_DEPTH - 1))
}

# classify_simple_command <is-nested> <word>...: the per-command half of
# classify_merge_commands.
classify_simple_command() {
  local is_wrapped="$1" word script=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      '{' | '}' | '!' | if | then | else | elif | do | while | until | time) is_wrapped=1; shift ;;
      *) [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || break; shift ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  case "${1##*/}" in
    cd | pushd | popd) HAS_DIRECTORY_CHANGE=1; return 0 ;;
    eval) shift; classify_merge_commands "$*" 1; return 0 ;;
    bash | sh | zsh)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in -*c*) script="${2:-}"; break ;; esac
        shift
      done
      [ -n "$script" ] && classify_merge_commands "$script" 1
      return 0 ;;
    env | command | exec | sudo | nohup | nice | timeout | xargs | stdbuf | caffeinate)
      is_wrapped=1
      while [ "$#" -gt 0 ] && [ "${1##*/}" != "gh" ]; do shift; done
      [ "$#" -gt 0 ] || return 0 ;;
  esac
  [ "${1##*/}" = "gh" ] || return 0
  [ "$1" = "gh" ] || is_wrapped=1
  shift
  while [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; do
    is_wrapped=1
    case "$1" in -R | --repo) shift ;; esac
    shift
  done
  [ "${1:-}" = "pr" ] || return 0
  shift
  while [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; do
    is_wrapped=1
    case "$1" in -R | --repo) shift ;; esac
    shift
  done
  [ "${1:-}" = "merge" ] || return 0
  MERGE_TOTAL=$((MERGE_TOTAL + 1))
  [ "$is_wrapped" -eq 0 ] && MERGE_CANONICAL=$((MERGE_CANONICAL + 1))
  return 0
}

# R-512, R-517, and R-514 on the merge path. A merge-commit strategy is denied
# from the command alone, before any gh call. Every other merge consults gh
# once, from the command's working directory: a rebase for the bundle
# conditions, and every merge for the Codex review section in the PR body.
MERGE_TOTAL=0
MERGE_CANONICAL=0
HAS_DIRECTORY_CHANGE=0
if [ "$IS_MERGE_CANDIDATE" -eq 1 ]; then
  if [ "$IS_SHELL_TOKENS_LOADED" -eq 1 ]; then
    classify_merge_commands "$CMD" 0
  else
    MERGE_TOTAL=1
  fi
fi
if [ "$MERGE_TOTAL" -gt 0 ]; then
  MERGE_COUNT="$MERGE_TOTAL"
  PARSEABLE_MERGE_COUNT=$(grep -oE "$GH_MERGE_PATTERN" <<< "$CMD" | wc -l | tr -d ' ')
  [ "$MERGE_COUNT" -le 1 ] && [ "$MERGE_CANONICAL" -eq 1 ] && [ "$PARSEABLE_MERGE_COUNT" -eq 1 ] || [ "$MERGE_COUNT" -gt 1 ] ||
    deny "R-517: this merge runs gh inside a brace group, subshell, control-flow keyword, eval or sh -c string, behind a wrapper or path, with quoted or escaped words, or with an option such as --repo/-R before the merge subcommand, a shape the hook cannot parse, so it cannot check the PR's Codex review section (R-517), strategy (R-512), or authorization (R-514). Re-run it as a bare \`gh pr merge <n> --squash [--repo <owner/repo>]\` on its own line."
  [ "$MERGE_COUNT" -le 1 ] ||
    deny "R-517: this command runs $MERGE_COUNT merges, and the hook reads one PR's body per merge command, so the others would merge without their Codex review being checked. Merge one PR per command."
  parse_merge_arguments
  if [ "$MERGE_HAS_MERGE_FLAG" -eq 1 ]; then
    deny "This merges the PR with a strategy R-512 does not allow. Feature branches squash-merge: one commit per feature on main, so the branch's work-in-progress history stays off the trunk. Re-run with --squash."
  fi
  read_merge_pr_view
  if [ "$MERGE_HAS_REBASE_FLAG" -eq 1 ]; then
    BUNDLE_VERDICT=$(read_bundle_verdict)
    [ "$BUNDLE_VERDICT" = "ok" ] ||
      deny "This rebase-merges the PR, which R-512 allows only for a bundle PR, and $BUNDLE_VERDICT A bundle carries the \`bundle\` label and one commit per ticket, each with its own \`Refs: <KEY>\` trailer line, so every ticket keeps exactly one commit on main. Otherwise re-run with --squash."
  fi
  CODEX_REVIEW_VERDICT=$(read_codex_review_verdict)
  [ "$CODEX_REVIEW_VERDICT" = "ok" ] ||
    deny "R-517: no PR merges before the blocking Codex review, and $CODEX_REVIEW_VERDICT Run the review with ~/.claude/prompts/codex-pr-review-prompt.md (or its recorded fallback when Codex is unavailable), fix or answer every finding, and add a \`## Codex review\` section to the PR body summarizing the findings and their dispositions; then merge again."
  ask "R-514: merging a PR needs explicit user authorization in the current turn, and 'merge when ready' from an earlier turn is not it. Confirm this specific merge now, or say so and it waits."
fi

TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
# Identity is defined once in repo-identity.sh (2026-09-16 audit item 5).
# -f guard: a failed source aborts the shell under set -e even behind ||.
REPO_IDENTITY_HELPER="$(dirname "${BASH_SOURCE[0]}")/repo-identity.sh"
is_global_repo=0
if [ -f "$REPO_IDENTITY_HELPER" ]; then
  source "$REPO_IDENTITY_HELPER"
  if is_governance_repo "$TOP"; then
    is_global_repo=1
  fi
fi
BRANCH=$(git -C "$TOP" symbolic-ref --short HEAD 2>/dev/null || true)
on_trunk=0
case "$BRANCH" in main | master) on_trunk=1 ;; esac

# R-514 on the push path: the target branch is the explicit refspec when one is
# given, and the checked-out branch otherwise.
if [ "$is_global_repo" -eq 0 ] && grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+push([[:space:]]|$)' <<< "$CMD"; then
  PUSH_ARGS=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+push[^;&|]*' | head -1 |
    sed -E 's/^git[[:space:]]+push[[:space:]]*//' | tr ' ' '\n' | grep -vE '^(-.*)?$' || true)
  REFSPEC=$(printf '%s\n' "$PUSH_ARGS" | sed -n '2p')
  # Resolve the refspec to a branch name rather than pattern-matching its text:
  # `HEAD`, `refs/heads/main`, `+main`, and `HEAD:refs/heads/main` all name the
  # same destination as a bare `main`, and matching literally missed all four.
  TARGET="$BRANCH"
  if [ -n "$REFSPEC" ]; then
    TARGET="${REFSPEC##*:}"
    TARGET="${TARGET#+}"
    TARGET="${TARGET#refs/heads/}"
    [ "$TARGET" = "HEAD" ] && TARGET="$BRANCH"
  fi
  case "$TARGET" in
    main | master)
      ask "R-514: this pushes straight to $TARGET, which is only for an express request after the risks are named. The default path is a branch and a PR. Confirm the direct push, or redirect it to a feature branch." ;;
  esac
fi

# Commit-time advisories. Staged paths are unioned with any `git add` argument
# in the same command, because a chained `git add X && git commit` runs this
# hook before anything reaches the index.
grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+commit([[:space:]]|$)' <<< "$CMD" || exit 0
CHANGED=$(git -C "$TOP" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
ADDED=$(git -C "$TOP" diff --cached --name-only --diff-filter=A 2>/dev/null || true)
if grep -qE 'git[[:space:]]+add[[:space:]]' <<< "$CMD"; then
  WORKING=$(git -C "$TOP" status --porcelain 2>/dev/null || true)
  CHANGED="$CHANGED
$(printf '%s\n' "$WORKING" | awk 'NF {print $NF}')"
  ADDED="$ADDED
$(printf '%s\n' "$WORKING" | awk '/^(\?\?|A)/ {print $NF}')"
fi
CHANGED=$(printf '%s\n' "$CHANGED" | grep -v '^$' | sort -u || true)
[ -z "$CHANGED" ] && exit 0

# R-511: breadth is the signal. A change touching this many files across this
# many directories is the cross-cutting refactor that wants its own branch.
if [ "$is_global_repo" -eq 0 ] && [ "$on_trunk" -eq 1 ]; then
  FILE_COUNT=$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')
  # dirname per line, not via xargs: a path holding a quote or a space makes
  # xargs exit non-zero, and under pipefail that took the whole advisory with it.
  DIR_COUNT=$(while IFS= read -r changed_path; do
    [ -n "$changed_path" ] && dirname "$changed_path"
  done <<<"$CHANGED" | sort -u | wc -l | tr -d ' ')
  if [ "$FILE_COUNT" -ge 5 ] && [ "$DIR_COUNT" -ge 3 ]; then
    echo "git-workflow-guard: this commit spans $FILE_COUNT files across $DIR_COUNT directories on $BRANCH. R-511 runs a cross-cutting change on its own branch, one at a time, so it can be reviewed and reverted as a unit." >&2
  fi
fi

# R-508: a new route, handler, page, or setup change is user-facing by
# definition, and the README is where a user finds out. The route patterns
# cover every stack the R-607 checklist (enforce/require-feature-checklist.sh,
# BUILTIN_TRIGGERS) treats as a new route: Next.js pages and route handlers,
# Nuxt pages, Nitro server/api and server/routes, FastAPI routers, and Express
# routes and handlers. That script is copied standalone into product
# repositories, so it cannot source a shared list; the git-workflow-guard
# fixture reads its triggers and fails when this list stops covering them.
R508_SURFACE_PATTERNS=(
  '(^|/)(routes|handlers)/'
  '(^|/)(page|route)\.(tsx|ts|jsx|js)$'
  '(^|/)app/pages/.+\.vue$'
  '(^|/)server/api/'
  '(^|/)app/routers/[^/]+\.py$'
  '(^|/)features/'
  '(^|/)\.env\.example$'
  '(^|/)docker-compose[^/]*\.ya?ml$'
  '(^|/)Dockerfile$'
)
SURFACE_GREP_ARGS=()
for surface_pattern in "${R508_SURFACE_PATTERNS[@]}"; do SURFACE_GREP_ARGS+=(-e "$surface_pattern"); done
SURFACE=$(printf '%s\n' "$ADDED" | grep -v '^$' |
  grep -E "${SURFACE_GREP_ARGS[@]}" | head -3 || true)
if [ -n "$SURFACE" ] && ! grep -qiE '(^|/)README[^/]*$' <<< "$CHANGED"; then
  echo "git-workflow-guard: this commit adds a user-facing surface ($(printf '%s' "$SURFACE" | tr '\n' ' ')) and touches no README. R-508 updates the README in the same commit as the feature, structure, or setup change." >&2
fi
exit 0
