#!/usr/bin/env bash
# scaffold.sh: the shell half of the feature-create skill (2026-09-17 skills
# audit, S-1). Steps 1 to 4 and 6 of the skill are input parsing, refusal
# checks, a worktree, an install, a baseline test run, and a scaffold commit;
# run by hand they were skipped or misordered, and two of them assumed the
# cwd was the repo root and the default branch was main. This script does
# them in order with an exit code per stop, and leaves the two judgement
# steps to the session: the acceptance criteria in the user story (read from
# the plan) and the execution recommendation.
#
# Usage: scaffold.sh <slug> [plan-path] [--ticket <key>] [--worktree-parent <dir>]
#                    [--base <branch>] [--no-fetch]
# --ticket writes the key onto the user story's **Ticket:** line and as the
# Refs: trailer of the scaffold commit (R-605); without it the story carries
# the <ticket-key> placeholder for the session to fill.
# Environment: FEATURE_CREATE_INSTALL_CMD and FEATURE_CREATE_TEST_CMD override
# the detected install and test commands (set either to "skip" to omit it).
#
# Exit codes: 0 done; 2 usage (bad slug, missing argument); 3 no plan found;
# 4 several plans match (candidates printed, the session asks the user);
# 5 branch feat/<slug> exists; 6 worktree directory exists; 7 baseline tests
# failed (worktree preserved, nothing scaffolded); 8 git operation failed.
set -uo pipefail

say() { printf 'feature-create: %s\n' "$*"; }
die() { printf 'feature-create: %s\n' "$*" >&2; exit "${2:-8}"; }

SLUG=""; PLAN=""; WORKTREE_PARENT=""; BASE=""; FETCH=1; TICKET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree-parent) WORKTREE_PARENT="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --ticket) TICKET="${2:-}"; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    --*) die "unknown option $1" 2 ;;
    *) if [ -z "$SLUG" ]; then SLUG="$1"; elif [ -z "$PLAN" ]; then PLAN="$1"; else die "unexpected argument $1" 2; fi; shift ;;
  esac
done
[ -n "$SLUG" ] || die "usage: scaffold.sh <slug> [plan-path] [--ticket <key>] [--worktree-parent <dir>] [--base <branch>] [--no-fetch]" 2
grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' <<< "$SLUG" || die "slug '$SLUG' must be lowercase words joined by single hyphens" 2

# --- Step 1: inputs --------------------------------------------------------
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository" 8
cd "$ROOT" || die "cannot enter $ROOT" 8
PROJECT=$(basename "$ROOT")
SLUG_UPPER=$(printf '%s' "$SLUG" | tr '[:lower:]' '[:upper:]')
TITLE=$(printf '%s' "$SLUG" | tr '-' ' ' | awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')
[ -n "$WORKTREE_PARENT" ] || WORKTREE_PARENT="$ROOT/../$PROJECT-worktrees"
WORKTREE="$WORKTREE_PARENT/$SLUG"
BRANCH="feat/$SLUG"

if [ -n "$PLAN" ]; then
  [ -f "$PLAN" ] || die "plan file $PLAN does not exist" 3
else
  matches=$(ls -t docs/superpowers/plans/*"$SLUG"* 2>/dev/null || true)
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    die "no plan file matches '$SLUG' under docs/superpowers/plans/; pass the path explicitly" 3
  elif [ "$count" -gt 1 ]; then
    printf 'feature-create: several plans match %s; pass one explicitly:\n%s\n' "$SLUG" "$matches" >&2
    exit 4
  fi
  PLAN="$matches"
fi

# --- Step 2: refusals -------------------------------------------------------
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "branch $BRANCH already exists; use a different slug or delete the existing branch" 5
fi
[ ! -e "$WORKTREE" ] || die "worktree directory already exists at $WORKTREE; remove it or use a different slug" 6

# --- Step 3: worktree from a fresh default branch ---------------------------
if [ -z "$BASE" ]; then
  BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  if [ -z "$BASE" ]; then
    for candidate in main master; do
      git show-ref --verify --quiet "refs/heads/$candidate" && { BASE="$candidate"; break; }
    done
  fi
fi
[ -n "$BASE" ] || die "cannot determine the default branch; pass --base <branch>" 8
BASE_REF="$BASE"
if [ "$FETCH" -eq 1 ] && git remote get-url origin >/dev/null 2>&1; then
  if git fetch -q origin "$BASE" 2>/dev/null; then BASE_REF="origin/$BASE"; else say "warning: fetch of origin/$BASE failed; branching from local $BASE"; fi
fi
mkdir -p "$WORKTREE_PARENT" || die "cannot create $WORKTREE_PARENT" 8
git worktree add -q "$WORKTREE" -b "$BRANCH" "$BASE_REF" || die "git worktree add failed" 8
say "created worktree $WORKTREE on branch $BRANCH from $BASE_REF"

# --- Step 4: install and baseline -------------------------------------------
cd "$WORKTREE" || die "cannot enter $WORKTREE" 8
INSTALL_CMD="${FEATURE_CREATE_INSTALL_CMD:-}"
TEST_CMD="${FEATURE_CREATE_TEST_CMD:-}"
if [ -z "$INSTALL_CMD" ]; then
  if [ -f pnpm-lock.yaml ]; then INSTALL_CMD="pnpm install --frozen-lockfile"
  elif [ -f package-lock.json ]; then INSTALL_CMD="npm ci"
  elif [ -f yarn.lock ]; then INSTALL_CMD="yarn install --frozen-lockfile"
  else INSTALL_CMD="skip"; fi
fi
if [ -z "$TEST_CMD" ]; then
  if [ -f package.json ] && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    if [ -f pnpm-lock.yaml ]; then TEST_CMD="pnpm test"; elif [ -f yarn.lock ]; then TEST_CMD="yarn test"; else TEST_CMD="npm test"; fi
  else TEST_CMD="skip"; fi
fi
if [ "$INSTALL_CMD" != "skip" ]; then
  say "installing: $INSTALL_CMD"
  sh -c "$INSTALL_CMD" || die "install failed ($INSTALL_CMD); worktree preserved at $WORKTREE" 8
else
  say "no lockfile found; install skipped"
fi
if [ "$TEST_CMD" != "skip" ]; then
  say "baseline: $TEST_CMD"
  if ! sh -c "$TEST_CMD"; then
    die "baseline tests failed in the new worktree ($TEST_CMD). The worktree is preserved at $WORKTREE for debugging, but scaffolding will not proceed. Fix the failing tests on $BASE first." 7
  fi
else
  say "no test script found; baseline skipped"
fi

# --- Step 5 (mechanical half): scaffold ------------------------------------
scaffolded=()
if [ -f docs/feature-list/features.md ]; then
  printf '| %s | **Planned** | US-%s |\n' "$TITLE" "$SLUG_UPPER" >> docs/feature-list/features.md
  scaffolded+=(docs/feature-list/features.md)
  say "appended a Planned row to docs/feature-list/features.md; move it into the matching section if one exists"
else
  say "no docs/feature-list/features.md; feature-list row skipped"
fi
if [ -d docs/user-stories ]; then
  STORY="docs/user-stories/$SLUG.md"
  cat > "$STORY" <<EOF
# $TITLE User Stories

## US-$SLUG_UPPER-001: <Primary user flow>

**As** a user
**I want to** <action from plan>
**So that** <benefit from plan>

**Acceptance criteria:**

1. <!-- Derive from the plan's task descriptions; one criterion per testable behavior -->

**E2E test:** \`e2e/$SLUG.spec.ts\`
**Ticket:** ${TICKET:-<ticket-key>}
EOF
  scaffolded+=("$STORY")
  say "wrote $STORY; fill the acceptance criteria from $PLAN"
else
  say "no docs/user-stories/; user story skipped"
fi

# --- Step 6: commit ----------------------------------------------------------
COMMIT=""
if [ "${#scaffolded[@]}" -gt 0 ]; then
  if [ -n "$TICKET" ]; then
    git add "${scaffolded[@]}" && git commit -q -m "chore(docs): scaffold docs for $BRANCH" -m "Refs: $TICKET" || die "scaffold commit failed" 8
  else
    git add "${scaffolded[@]}" && git commit -q -m "chore(docs): scaffold docs for $BRANCH" || die "scaffold commit failed" 8
  fi
  COMMIT=$(git rev-parse --short HEAD)
  say "committed $COMMIT: chore(docs): scaffold docs for $BRANCH${TICKET:+ (Refs: $TICKET)}"
else
  say "nothing scaffolded; no commit"
fi

# Query-parameter signal for the skill's Step 5d: ask only when the plan
# mentions one.
if grep -qiE 'query param|searchParams|req\.query|useSearchParams|\?[a-zA-Z]+=' "$ROOT/$PLAN" 2>/dev/null || grep -qiE 'query param|searchParams|req\.query|useSearchParams|\?[a-zA-Z]+=' "$PLAN" 2>/dev/null; then
  QUERY_PARAMS=yes
else
  QUERY_PARAMS=no
fi

cat <<EOF
feature-create: done
  worktree:      $WORKTREE
  branch:        $BRANCH (from $BASE_REF)
  plan:          $PLAN
  scaffolded:    ${scaffolded[*]:-none}
  commit:        ${COMMIT:-none}
  query params:  $QUERY_PARAMS (plan mentions query parameters; ask the user only when yes)
EOF
