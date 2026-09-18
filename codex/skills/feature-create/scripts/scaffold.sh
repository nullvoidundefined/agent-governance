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
# Usage: scaffold.sh <slug> --area <area> [plan-path] [--ticket <key>]
#                    [--worktree-parent <dir>] [--base <branch>] [--no-fetch]
# --area names the product area (R-607): the story is appended to
# docs/user-stories/<area>.md as the next free US-<AREA>-NNN, and the feature
# row is inserted into the features-list section whose heading slugifies to
# the area (a new section at the end when none does). Absent product docs are
# seeded from the harness templates in prompts/.
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The templates sit beside skills/ in the harness tree. A Codex or Cursor port
# of this script lives under ~/.codex or ~/.cursor, which carry no prompts/,
# so it falls back to the synced ~/.claude.
PROMPTS_DIR=$(cd "$SCRIPT_DIR/../../.." && pwd)/prompts
[ -f "$PROMPTS_DIR/feature-list-template.md" ] || PROMPTS_DIR="$HOME/.claude/prompts"
SLUG=""; PLAN=""; WORKTREE_PARENT=""; BASE=""; FETCH=1; TICKET=""; AREA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree-parent) WORKTREE_PARENT="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --ticket) TICKET="${2:-}"; shift 2 ;;
    --area) AREA="${2:-}"; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    --*) die "unknown option $1" 2 ;;
    *) if [ -z "$SLUG" ]; then SLUG="$1"; elif [ -z "$PLAN" ]; then PLAN="$1"; else die "unexpected argument $1" 2; fi; shift ;;
  esac
done
[ -n "$SLUG" ] || die "usage: scaffold.sh <slug> --area <area> [plan-path] [--ticket <key>] [--worktree-parent <dir>] [--base <branch>] [--no-fetch]" 2
printf '%s' "$SLUG" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || die "slug '$SLUG' must be lowercase words joined by single hyphens" 2

# --- Step 1: inputs --------------------------------------------------------
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository" 8
cd "$ROOT" || die "cannot enter $ROOT" 8
PROJECT=$(basename "$ROOT")

# slugify_heading: reads headings on stdin, prints each as a lowercase
# hyphenated slug, so "## Authentication & Account" names the area
# authentication-account.
slugify_heading() { sed -e 's/^## *//' | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//'; }

# list_known_areas: prints the areas the repository already has, from the
# story files and the features-list headings, one per line.
list_known_areas() {
  { ls docs/user-stories/*.md 2>/dev/null | sed -e 's#.*/##' -e 's#\.md$##' | grep -vx README
    grep -E '^## ' docs/feature-list/features.md 2>/dev/null | slugify_heading; } | sort -u
}

if [ -z "$AREA" ]; then
  printf 'feature-create: --area <area> is required (R-607: stories live in one file per product area). Known areas:\n%s\n' "$(list_known_areas | sed 's/^/  /')" >&2
  exit 2
fi
printf '%s' "$AREA" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || die "area '$AREA' must be lowercase words joined by single hyphens" 2
AREA_UPPER=$(printf '%s' "$AREA" | tr '[:lower:]' '[:upper:]')
AREA_TITLE=$(printf '%s' "$AREA" | tr '-' ' ' | awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')
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
# R-607: seed any absent product doc from the templates, append the story to
# the area file, index a new area file, and insert the feature row into the
# area's section of the features list.
FEATURES=docs/feature-list/features.md
STORIES_README=docs/user-stories/README.md
STORY_FILE="docs/user-stories/$AREA.md"
E2E_PATH="e2e/$SLUG.spec.ts"
TODAY=$(date +%Y-%m-%d)

# render_template <template>: prints a prompts/ template with every
# placeholder this scaffold knows substituted.
render_template() {
  sed -e "s#{{PROJECT}}#$PROJECT#g" -e "s#{{DATE}}#$TODAY#g" -e "s#{{AREA_TITLE}}#$AREA_TITLE#g" \
      -e "s#{{STORY_ID}}#$STORY_ID#g" -e "s#{{STORY_TITLE}}#$TITLE#g" -e "s#{{E2E_PATH}}#$E2E_PATH#g" \
      -e "s#{{TICKET}}#${TICKET:-<ticket-key>}#g" "$PROMPTS_DIR/$1"
}

# next_story_id: prints US-<AREA>-NNN, one past the highest number the area
# file already uses (001 for a new file); ids are never reused.
next_story_id() {
  local highest
  highest=$(grep -oE "US-$AREA_UPPER-[0-9]+" "$STORY_FILE" 2>/dev/null | sed "s/^US-$AREA_UPPER-//" | sort -n | tail -1)
  printf 'US-%s-%03d' "$AREA_UPPER" "$(( 10#${highest:-0} + 1 ))"
}

# insert_feature_row <row>: puts the row after the last table line of the
# section whose heading slugifies to the area, or appends a new section with
# a table when no heading matches; rewrites the Last updated line.
insert_feature_row() {
  local row="$1" tmp
  tmp=$(mktemp)
  awk -v area="$AREA" -v title="$AREA_TITLE" -v row="$row" '
    function slug(h) { h = tolower(h); sub(/^## */, "", h); gsub(/[^a-z0-9]+/, "-", h); sub(/^-/, "", h); sub(/-$/, "", h); return h }
    { lines[++n] = $0 }
    /^## / { if (slug($0) == area) { start = n } else if (start && !stop) { stop = n } }
    END {
      if (!start) {
        for (i = 1; i <= n; i++) print lines[i]
        print ""; print "## " title; print ""
        print "| Feature | Status | Notes |"; print "| ------- | ------ | ----- |"; print row
        exit
      }
      last = 0; end = stop ? stop - 1 : n
      for (i = start + 1; i <= end; i++) if (lines[i] ~ /^\|/) last = i
      for (i = 1; i <= n; i++) {
        print lines[i]
        if (last && i == last) print row
        if (!last && i == start) { print ""; print "| Feature | Status | Notes |"; print "| ------- | ------ | ----- |"; print row }
      }
    }' "$FEATURES" > "$tmp" && mv "$tmp" "$FEATURES"
  if grep -q '^Last updated: ' "$FEATURES"; then
    sed -i.bak -e "s#^Last updated: .*#Last updated: $TODAY ($SLUG planned)#" "$FEATURES" && rm -f "$FEATURES.bak"
  else
    # R-607 requires the line on every change; a list that never had one
    # gains it under the title.
    tmp=$(mktemp)
    awk -v line="Last updated: $TODAY ($SLUG planned)" 'NR == 1 { print; print ""; print line; next } { print }' "$FEATURES" > "$tmp" && mv "$tmp" "$FEATURES"
  fi
}

scaffolded=()
for template in feature-list-template.md user-stories-readme-template.md user-story-area-template.md; do
  [ -f "$PROMPTS_DIR/$template" ] || die "product-doc templates not found under $PROMPTS_DIR (missing $template); sync the harness (~/.claude) and re-run" 8
done
mkdir -p docs/feature-list docs/user-stories
STORY_ID=$(next_story_id)
if [ ! -f "$FEATURES" ]; then
  render_template feature-list-template.md > "$FEATURES"
  say "seeded $FEATURES from the harness template"
fi
if [ ! -f "$STORIES_README" ]; then
  render_template user-stories-readme-template.md > "$STORIES_README"
  say "seeded $STORIES_README from the harness template"
fi
if [ -f "$STORY_FILE" ]; then
  { printf '\n'; render_template user-story-area-template.md | awk '/^## /{on=1} on'; } >> "$STORY_FILE"
else
  render_template user-story-area-template.md > "$STORY_FILE"
  printf '| `%s.md` | %s |\n' "$AREA" "$AREA_TITLE" >> "$STORIES_README"
fi
insert_feature_row "| $TITLE | **Planned** | $STORY_ID |"
scaffolded+=("$FEATURES" "$STORIES_README" "$STORY_FILE")
say "appended $STORY_ID to $STORY_FILE and a Planned row to the $AREA_TITLE section of $FEATURES; fill the acceptance criteria from $PLAN"

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
