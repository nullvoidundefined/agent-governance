#!/usr/bin/env bash
# git-workflow-guard.sh: the R-5xx rules that are decidable from a git or gh
# command plus the index. One PreToolUse(Bash) hook, four rules:
#   R-514  a push whose target branch is main/master asks first, and so does
#          `gh pr merge` (authorization is per turn, never standing)
#   R-512  `gh pr merge --merge` is denied, and so is `--rebase` unless the PR
#          is a bundle (the `bundle` label, a `Refs:` trailer on every commit,
#          read from `gh pr view`); feature branches squash-merge into one
#          commit per feature
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

grep -qE '(^|[;&|])[[:space:]]*(git[[:space:]]+(push|commit)|gh[[:space:]]+pr[[:space:]]+merge)([[:space:]]|$)' <<< "$CMD" || exit 0

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

# read_merge_target_arguments: fills the caller's view_arguments array with
# the `gh pr view` arguments naming the same PR the merge names: the first
# positional argument after `merge` (a number, URL, or branch), plus any
# --repo/-R. The values of merge's other value-taking flags are skipped so a
# subject or head SHA is never mistaken for the PR. Word splitting is on
# whitespace only; a quoted value holding a space can at worst name the wrong
# PR, which gh then fails to find or reports without the bundle label.
read_merge_target_arguments() {
  local merge_arguments merge_token skip_next=0 repo_next=0 pr_selector=""
  merge_arguments=$(printf '%s' "$CMD" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[^;&|]*' | head -1 |
    sed -E 's/^gh[[:space:]]+pr[[:space:]]+merge[[:space:]]*//' || true)
  for merge_token in $merge_arguments; do
    if [ "$repo_next" -eq 1 ]; then view_arguments+=(--repo "$merge_token"); repo_next=0; continue; fi
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$merge_token" in
      -R | --repo) repo_next=1 ;;
      --repo=*) view_arguments+=("$merge_token") ;;
      -t | --subject | -b | --body | -F | --body-file | -A | --author-email | --match-head-commit) skip_next=1 ;;
      -*) ;;
      *) [ -z "$pr_selector" ] && pr_selector="$merge_token" ;;
    esac
  done
  [ -n "$pr_selector" ] && view_arguments=("$pr_selector" ${view_arguments[@]+"${view_arguments[@]}"})
  return 0
}

# read_bundle_verdict: prints "ok" when the PR being merged is a bundle PR
# (R-512's exception): it carries the `bundle` label and every commit message
# holds a `Refs: <KEY>` trailer line. Otherwise prints the sentence naming the
# first missing condition. The PR is the first positional argument after
# `merge`, or the current branch's PR when none is given, the same resolution
# gh itself uses. Fail-closed: a gh that errors or answers with anything jq
# cannot read is reported as unverifiable, never as a bundle. CLAUDE_GH_CMD
# replaces gh for the fixture.
read_bundle_verdict() {
  local gh_command="${CLAUDE_GH_CMD:-gh}" pr_json
  local -a view_arguments=()
  read_merge_target_arguments
  if ! pr_json=$(cd "$CWD" 2>/dev/null && "$gh_command" pr view ${view_arguments[@]+"${view_arguments[@]}"} --json labels,commits 2>/dev/null) ||
    ! printf '%s' "$pr_json" | jq -e '(.labels | type == "array") and (.commits | type == "array")' >/dev/null 2>&1; then
    echo "gh pr view could not confirm the PR's labels and commits, so the bundle conditions are unverified."
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
  echo ok
}

# R-512 and R-514 on the merge path. A squash or merge-commit decision needs
# no repository context: the command alone carries both the strategy and the
# fact that a merge is imminent. Only a rebase consults gh, from the command's
# working directory, to check the bundle conditions.
if grep -qE '(^|[;&|])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' <<< "$CMD"; then
  if grep -qE '[[:space:]]--merge([[:space:]]|=|$)' <<< "$CMD"; then
    deny "This merges the PR with a strategy R-512 does not allow. Feature branches squash-merge: one commit per feature on main, so the branch's work-in-progress history stays off the trunk. Re-run with --squash."
  fi
  if grep -qE '[[:space:]]--rebase([[:space:]]|=|$)' <<< "$CMD"; then
    BUNDLE_VERDICT=$(read_bundle_verdict)
    [ "$BUNDLE_VERDICT" = "ok" ] ||
      deny "This rebase-merges the PR, which R-512 allows only for a bundle PR, and $BUNDLE_VERDICT A bundle carries the \`bundle\` label and one commit per ticket, each with its own \`Refs: <KEY>\` trailer line, so every ticket keeps exactly one commit on main. Otherwise re-run with --squash."
  fi
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
