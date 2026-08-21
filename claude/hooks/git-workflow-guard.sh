#!/usr/bin/env bash
# git-workflow-guard.sh: the R-5xx rules that are decidable from a git or gh
# command plus the index. One PreToolUse(Bash) hook, four rules:
#   R-514  a push whose target branch is main/master asks first, and so does
#          `gh pr merge` (authorization is per turn, never standing)
#   R-512  `gh pr merge --merge` / `--rebase` is denied; feature branches
#          squash-merge into one commit per feature
#   R-511  advisory: a cross-cutting change (5+ files, 3+ directories) landing
#          directly on main wants its own branch
#   R-508  advisory: a commit that adds a user-facing surface or changes setup
#          and touches no README
#
# The ~/.claude repo is exempt from the two main-branch rules: main IS its
# working branch, and its pushes are already gated by global-repo-push-guard
# for R-106. Advisories print to stderr and never block.
set -euo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*(git[[:space:]]+(push|commit)|gh[[:space:]]+pr[[:space:]]+merge)([[:space:]]|$)' || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"

ask() {
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$1" | grep -oE 'R-[0-9]{3}' | head -1)" "git-workflow-guard" "ask"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

deny() {
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$1" | grep -oE 'R-[0-9]{3}' | head -1)" "git-workflow-guard" "deny"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# R-512 and R-514 on the merge path. A merge needs no repository context: the
# command alone carries both the strategy and the fact that a merge is imminent.
if printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
  if printf '%s' "$CMD" | grep -qE '[[:space:]]--(merge|rebase)([[:space:]]|=|$)'; then
    deny "This merges the PR with a strategy R-512 does not allow. Feature branches squash-merge: one commit per feature on main, so the branch's work-in-progress history stays off the trunk. Re-run with --squash."
  fi
  ask "R-514: merging a PR needs explicit user authorization in the current turn, and 'merge when ready' from an earlier turn is not it. Confirm this specific merge now, or say so and it waits."
fi

TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
TOP_REAL=$(cd "$TOP" 2>/dev/null && pwd -P) || exit 0
GLOBAL_REPO=$(cd "$HOME/.claude" 2>/dev/null && pwd -P) || GLOBAL_REPO=""
is_global_repo=0
[ -n "$GLOBAL_REPO" ] && [ "$TOP_REAL" = "$GLOBAL_REPO" ] && is_global_repo=1
BRANCH=$(git -C "$TOP" symbolic-ref --short HEAD 2>/dev/null || true)
on_trunk=0
case "$BRANCH" in main | master) on_trunk=1 ;; esac

# R-514 on the push path: the target branch is the explicit refspec when one is
# given, and the checked-out branch otherwise.
if [ "$is_global_repo" -eq 0 ] && printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+push([[:space:]]|$)'; then
  PUSH_ARGS=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+push[^;&|]*' | head -1 |
    sed -E 's/^git[[:space:]]+push[[:space:]]*//' | tr ' ' '\n' | grep -vE '^(-.*)?$' || true)
  REFSPEC=$(printf '%s\n' "$PUSH_ARGS" | sed -n '2p')
  TARGET="$BRANCH"
  [ -n "$REFSPEC" ] && TARGET="${REFSPEC##*:}"
  case "$TARGET" in
    main | master)
      ask "R-514: this pushes straight to $TARGET, which is only for an express request after the risks are named. The default path is a branch and a PR. Confirm the direct push, or redirect it to a feature branch." ;;
  esac
fi

# Commit-time advisories. Staged paths are unioned with any `git add` argument
# in the same command, because a chained `git add X && git commit` runs this
# hook before anything reaches the index.
printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+commit([[:space:]]|$)' || exit 0
CHANGED=$(git -C "$TOP" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
ADDED=$(git -C "$TOP" diff --cached --name-only --diff-filter=A 2>/dev/null || true)
if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+add[[:space:]]'; then
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
  DIR_COUNT=$(printf '%s\n' "$CHANGED" | xargs -n1 dirname 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "$FILE_COUNT" -ge 5 ] && [ "$DIR_COUNT" -ge 3 ]; then
    echo "git-workflow-guard: this commit spans $FILE_COUNT files across $DIR_COUNT directories on $BRANCH. R-511 runs a cross-cutting change on its own branch, one at a time, so it can be reviewed and reverted as a unit." >&2
  fi
fi

# R-508: a new route, handler, page, or setup change is user-facing by
# definition, and the README is where a user finds out.
SURFACE=$(printf '%s\n' "$ADDED" | grep -v '^$' |
  grep -E '(^|/)(routes|handlers)/|(^|/)page\.tsx$|(^|/)route\.ts$|(^|/)features/|(^|/)\.env\.example$|(^|/)docker-compose[^/]*\.ya?ml$|(^|/)Dockerfile$' | head -3 || true)
if [ -n "$SURFACE" ] && ! printf '%s\n' "$CHANGED" | grep -qiE '(^|/)README[^/]*$'; then
  echo "git-workflow-guard: this commit adds a user-facing surface ($(printf '%s' "$SURFACE" | tr '\n' ' ')) and touches no README. R-508 updates the README in the same commit as the feature, structure, or setup change." >&2
fi
exit 0
