#!/usr/bin/env bash
# setup.sh: the repo-setup skill's deterministic half. Brings a GitHub
# repository to the hygiene baseline, or audits it against that baseline with
# --check, so a new repository never starts without CI, dependency updates,
# review automation, and protected branches. Idempotent: every step checks
# before it writes, so re-running on a compliant repository changes nothing.
#
# Baseline (each item is one line of the report):
#   ci            .github/workflows/ci.yml with lint and test jobs for the
#                 detected stack (node, python, go, ruby), job name "ci" so
#                 the ruleset below can require it
#   dependabot    .github/dependabot.yml: github-actions weekly plus the
#                 stack's package ecosystem
#   pr-template   .github/pull_request_template.md
#   gitignore     a .gitignore exists (node_modules, .env*, build output)
#   staging       a staging branch exists (created from the default branch)
#   protect-refs  ruleset "protect-refs": no deletion, no force push on main
#                 and staging, no bypass for anyone
#   protect-merge ruleset "protect-merge": changes to main and staging land
#                 by pull request with the "ci" status check green; repo
#                 admins may bypass on express request (R-514)
#   merge-policy  squash merge only (R-512), delete branch on merge, no
#                 auto-merge
#   alerts        Dependabot vulnerability alerts and security fixes on
#   secret-scan   secret scanning and push protection on (warns when the
#                 plan does not allow it)
#   greptile      the Greptile GitHub App is installed for the owner
#                 (cannot be installed by API; prints the install link)
#   harness       .claude/hooks/harness-bootstrap.sh registered at SessionStart
#                 in .claude/settings.json (merged with jq when the file
#                 exists): in a remote session it clones the agent-governance
#                 repository and syncs ~/.claude, so the session runs under
#                 the harness (R-003); the repository URL comes from
#                 --harness-repo or the origin of the ~/.claude/.sync-source
#                 checkout
#   product-docs  docs/feature-list/features.md, docs/user-stories/README.md,
#                 and scripts/require-feature-checklist.sh (R-607), written
#                 from the harness templates in prompts/ and the canonical
#                 enforce/require-feature-checklist.sh when absent, never
#                 overwritten; SKIPPED when .enforce.json sets productDocs to
#                 false, which --no-product-docs records for a library or
#                 tooling repository
#
# Usage: setup.sh <owner/repo> [--check] [--stack node|python|go|ruby]
#                 [--branches main,staging] [--required-reviews N]
#                 [--ci-context <check name>]   (default ci; the name of the
#                 status check protect-merge requires, for a repository whose
#                 workflow already exists under another job name)
#                 [--harness-repo <git url>]    (the agent-governance clone
#                 URL for the bootstrap hook)
#                 [--no-product-docs]           (opt a library or tooling
#                 repository out of R-607's product docs)
# Run from the repository's checkout (local files are written there).
# REPO_SETUP_GH_CMD overrides the gh binary (fixtures stub it).
# Exit: 0 baseline met (or applied); 1 with --check when any item is missing;
# 2 usage; 3 gh unavailable or not authenticated.
set -uo pipefail

GH="${REPO_SETUP_GH_CMD:-gh}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The product-doc templates and the canonical checklist sit beside skills/ in
# the harness tree; a Codex or Cursor port of this script lives under ~/.codex
# or ~/.cursor, which carry neither, so it falls back to the synced ~/.claude.
HARNESS_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
[ -f "$HARNESS_ROOT/enforce/require-feature-checklist.sh" ] || HARNESS_ROOT="$HOME/.claude"
REPO=""; CHECK=0; STACK=""; BRANCHES="main,staging"; REVIEWS=0; CI_CONTEXT="ci"; HARNESS_REPO=""; PRODUCT_DOCS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --stack) STACK="${2:-}"; shift 2 ;;
    --branches) BRANCHES="${2:-}"; shift 2 ;;
    --required-reviews) REVIEWS="${2:-0}"; shift 2 ;;
    --ci-context) CI_CONTEXT="${2:-ci}"; shift 2 ;;
    --harness-repo) HARNESS_REPO="${2:-}"; shift 2 ;;
    --no-product-docs) PRODUCT_DOCS=0; shift ;;
    --*) echo "repo-setup: unknown option $1" >&2; exit 2 ;;
    *) REPO="$1"; shift ;;
  esac
done
if [ -z "$REPO" ]; then
  REPO=$("$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi
printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || { echo "usage: setup.sh <owner/repo> [--check] [--stack s] [--branches a,b] [--required-reviews N] [--ci-context name]" >&2; exit 2; }
OWNER="${REPO%%/*}"
command -v "$GH" >/dev/null 2>&1 || { echo "repo-setup: gh is not installed" >&2; exit 3; }
"$GH" auth status >/dev/null 2>&1 || { echo "repo-setup: gh is not authenticated (gh auth login)" >&2; exit 3; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 2

if [ -z "$STACK" ]; then
  if [ -f package.json ]; then STACK=node
  elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then STACK=python
  elif [ -f go.mod ]; then STACK=go
  elif [ -f Gemfile ]; then STACK=ruby
  else STACK=node; fi
fi
case "$STACK" in node) ECOSYSTEM=npm ;; python) ECOSYSTEM=pip ;; go) ECOSYSTEM=gomod ;; ruby) ECOSYSTEM=bundler ;; *) echo "repo-setup: unknown stack $STACK" >&2; exit 2 ;; esac

missing=0
report() { printf '%-14s %-8s %s\n' "$1" "$2" "$3"; [ "$2" = "OK" ] || [ "$2" = "SKIPPED" ] || missing=$((missing + 1)); }
apply() { [ "$CHECK" -eq 0 ]; }

echo "repo-setup: $REPO (stack $STACK, branches $BRANCHES)$( [ "$CHECK" -eq 1 ] && printf ', check only')"

# --- local files -------------------------------------------------------------
write_if_absent() { # <path> <template> [sed expr]
  local path="$1" template="$2" expr="${3:-}"
  if [ -f "$path" ]; then report "$4" OK "$path present"; return; fi
  if apply; then
    mkdir -p "$(dirname "$path")"
    if [ -n "$expr" ]; then sed -e "$expr" "$SCRIPT_DIR/$template" > "$path"; else cp "$SCRIPT_DIR/$template" "$path"; fi
    report "$4" OK "$path written from $template"
  else
    report "$4" MISSING "$path absent"
  fi
}
# A repository that already runs CI under another file name (this repo's
# enforce.yml, job "fixtures") satisfies the item; the template is written
# only when no workflow exists at all, and --ci-context names the check the
# protect-merge ruleset requires.
existing_workflows=$(ls .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null | tr '\n' ' ' || true)
if [ -n "$existing_workflows" ]; then
  report ci OK "workflow present: ${existing_workflows% }; ruleset requires check '$CI_CONTEXT'"
else
  write_if_absent .github/workflows/ci.yml "template-ci-$STACK.yml" "" ci
fi
write_if_absent .github/dependabot.yml template-dependabot.yml "s/__ECOSYSTEM__/$ECOSYSTEM/" dependabot
write_if_absent .github/pull_request_template.md template-pull-request.md "" pr-template
write_if_absent .gitignore "template-gitignore-$STACK" "" gitignore

# --- harness bootstrap (R-003) ------------------------------------------------
# Every session runs under the synced harness. A cloud container starts with
# no ~/.claude, so the repository itself carries a SessionStart hook that
# clones the agent-governance repository and syncs it; the hook is written
# from the template with the repository URL substituted, and the settings
# entry is merged with jq so an existing .claude/settings.json keeps its
# other hooks.
if [ -z "$HARNESS_REPO" ] && [ -f "$HOME/.claude/.sync-source" ]; then
  HARNESS_REPO=$(git -C "$(cat "$HOME/.claude/.sync-source")" remote get-url origin 2>/dev/null || true)
fi
HAS_BOOTSTRAP=0
if [ -f .claude/settings.json ] && jq -e '[.hooks.SessionStart[]?.hooks[]?.command // "" | select(test("harness-bootstrap\\.sh"))] | length > 0' .claude/settings.json >/dev/null 2>&1 && [ -f .claude/hooks/harness-bootstrap.sh ]; then
  HAS_BOOTSTRAP=1
fi
# The harness repository itself runs its own harness-sync.sh directly (no
# clone needed: the checkout is the project), which satisfies the item.
if [ "$HAS_BOOTSTRAP" -eq 0 ] && [ -f claude/hooks/harness-sync.sh ] && [ -f .claude/settings.json ] && jq -e '[.hooks.SessionStart[]?.hooks[]?.command // "" | select(test("harness-sync\\.sh"))] | length > 0' .claude/settings.json >/dev/null 2>&1; then
  HAS_BOOTSTRAP=3
fi
if [ "$HAS_BOOTSTRAP" -eq 1 ]; then
  report harness OK ".claude/hooks/harness-bootstrap.sh registered at SessionStart"
elif [ "$HAS_BOOTSTRAP" -eq 3 ]; then
  report harness OK "this is the harness repository: .claude/settings.json runs claude/hooks/harness-sync.sh at SessionStart"
elif [ -z "$HARNESS_REPO" ]; then
  report harness MISSING "no agent-governance repository URL: pass --harness-repo <url> (or sync ~/.claude first so .sync-source names the checkout)"
elif apply; then
  mkdir -p .claude/hooks
  if [ ! -f .claude/hooks/harness-bootstrap.sh ]; then
    sed -e "s#__HARNESS_REPO__#$HARNESS_REPO#" "$SCRIPT_DIR/template-harness-bootstrap.sh" > .claude/hooks/harness-bootstrap.sh
    chmod +x .claude/hooks/harness-bootstrap.sh
  fi
  entry=$(jq -c '.hooks.SessionStart[0]' "$SCRIPT_DIR/template-claude-settings.json")
  if [ -f .claude/settings.json ]; then
    tmp=$(mktemp)
    if jq --argjson e "$entry" '.hooks //= {} | .hooks.SessionStart = ((.hooks.SessionStart // []) + [$e])' .claude/settings.json > "$tmp" 2>/dev/null; then
      mv "$tmp" .claude/settings.json
    else
      rm -f "$tmp"; report harness MISSING ".claude/settings.json is not valid JSON; fix it, then re-run"; HAS_BOOTSTRAP=2
    fi
  else
    cp "$SCRIPT_DIR/template-claude-settings.json" .claude/settings.json
  fi
  [ "$HAS_BOOTSTRAP" -eq 2 ] || report harness OK "wrote .claude/hooks/harness-bootstrap.sh (clones $HARNESS_REPO in a remote session) and registered it at SessionStart"
else
  report harness MISSING "no SessionStart hook runs .claude/hooks/harness-bootstrap.sh (R-003)"
fi

# --- product docs (R-607) ----------------------------------------------------
# An application repository keeps a features list and per-area user stories,
# and carries a copy of the feature checklist for its own git hook and CI (the
# harness push gate runs the harness copy, never this one). A library or
# tooling repository opts out once with --no-product-docs, recorded as data in
# .enforce.json so every later --check and the push gate read the same answer.
PRODUCT_DOCS_FILES=(docs/feature-list/features.md docs/user-stories/README.md scripts/require-feature-checklist.sh)
PROJECT_NAME=$(basename "$ROOT")
TODAY=$(date +%Y-%m-%d)

# is_product_docs_opted_out: true when .enforce.json sets productDocs to false.
is_product_docs_opted_out() {
  [ -f .enforce.json ] && jq -e '.productDocs == false' .enforce.json >/dev/null 2>&1
}

# record_product_docs_opt_out: merges productDocs:false into .enforce.json,
# keeping every other key; prints nothing, returns non-zero on invalid JSON.
record_product_docs_opt_out() {
  local tmp
  [ -f .enforce.json ] || printf '{}\n' > .enforce.json
  tmp=$(mktemp)
  if jq '.productDocs = false' .enforce.json > "$tmp" 2>/dev/null; then mv "$tmp" .enforce.json; else rm -f "$tmp"; return 1; fi
}

# render_product_doc_template <template> <path>: writes a prompts/ template to
# the path with the project name and today's date substituted.
render_product_doc_template() {
  mkdir -p "$(dirname "$2")"
  sed -e "s#{{PROJECT}}#$PROJECT_NAME#g" -e "s#{{DATE}}#$TODAY#g" "$HARNESS_ROOT/prompts/$1" > "$2"
}

# write_product_docs: writes each absent product doc; never overwrites.
write_product_docs() {
  [ -f docs/feature-list/features.md ] || render_product_doc_template feature-list-template.md docs/feature-list/features.md
  [ -f docs/user-stories/README.md ] || render_product_doc_template user-stories-readme-template.md docs/user-stories/README.md
  if [ ! -f scripts/require-feature-checklist.sh ]; then
    mkdir -p scripts
    cp "$HARNESS_ROOT/enforce/require-feature-checklist.sh" scripts/require-feature-checklist.sh
    chmod +x scripts/require-feature-checklist.sh
  fi
}

absent_docs=""
for f in "${PRODUCT_DOCS_FILES[@]}"; do [ -f "$f" ] || absent_docs="$absent_docs $f"; done
if is_product_docs_opted_out; then
  report product-docs SKIPPED ".enforce.json productDocs false (library or tooling repository)"
elif [ "$PRODUCT_DOCS" -eq 0 ]; then
  if ! apply; then
    report product-docs MISSING "--no-product-docs given with --check; re-run without --check to record the opt-out"
  elif record_product_docs_opt_out; then
    report product-docs SKIPPED "recorded productDocs false in .enforce.json"
  else
    report product-docs MISSING ".enforce.json is not valid JSON; fix it, then re-run"
  fi
elif [ -z "$absent_docs" ]; then
  report product-docs OK "features list, user stories index, and feature checklist present"
elif [ ! -f "$HARNESS_ROOT/prompts/feature-list-template.md" ] || [ ! -f "$HARNESS_ROOT/enforce/require-feature-checklist.sh" ]; then
  report product-docs MISSING "absent:${absent_docs}; harness templates not found under $HARNESS_ROOT (sync ~/.claude)"
elif apply; then
  write_product_docs
  report product-docs OK "wrote${absent_docs} (R-607)"
else
  report product-docs MISSING "absent:${absent_docs}"
fi

# --- branches ----------------------------------------------------------------
DEFAULT_BRANCH=$("$GH" api "repos/$REPO" --jq .default_branch 2>/dev/null || echo main)
IFS=',' read -r -a BRANCH_LIST <<< "$BRANCHES"
for branch in "${BRANCH_LIST[@]}"; do
  [ "$branch" = "$DEFAULT_BRANCH" ] && continue
  if "$GH" api "repos/$REPO/branches/$branch" >/dev/null 2>&1; then
    report "$branch" OK "branch exists"
  elif apply; then
    sha=$("$GH" api "repos/$REPO/git/ref/heads/$DEFAULT_BRANCH" --jq .object.sha 2>/dev/null || true)
    if [ -n "$sha" ] && "$GH" api -X POST "repos/$REPO/git/refs" -f "ref=refs/heads/$branch" -f "sha=$sha" >/dev/null 2>&1; then
      report "$branch" OK "branch created from $DEFAULT_BRANCH"
    else
      report "$branch" MISSING "could not create branch $branch"
    fi
  else
    report "$branch" MISSING "branch absent"
  fi
done

# --- rulesets ----------------------------------------------------------------
refs_json=$(printf '%s' "$BRANCHES" | tr ',' '\n' | sed 's#^#"refs/heads/#; s#$#"#' | paste -sd, -)
EXISTING=$("$GH" api "repos/$REPO/rulesets" --jq '.[].name' 2>/dev/null || true)
ensure_ruleset() { # <name> <json>
  local name="$1" json="$2" tmp
  if printf '%s\n' "$EXISTING" | grep -qx "$name"; then report "$name" OK "ruleset present"; return; fi
  if apply; then
    tmp=$(mktemp); printf '%s' "$json" > "$tmp"
    if "$GH" api -X POST "repos/$REPO/rulesets" --input "$tmp" >/dev/null 2>&1; then report "$name" OK "ruleset created"; else report "$name" MISSING "ruleset creation failed (admin token needed)"; fi
    rm -f "$tmp"
  else
    report "$name" MISSING "ruleset absent"
  fi
}
ensure_ruleset protect-refs "{\"name\":\"protect-refs\",\"target\":\"branch\",\"enforcement\":\"active\",\"bypass_actors\":[],\"conditions\":{\"ref_name\":{\"include\":[$refs_json],\"exclude\":[]}},\"rules\":[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"}]}"
ensure_ruleset protect-merge "{\"name\":\"protect-merge\",\"target\":\"branch\",\"enforcement\":\"active\",\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"always\"}],\"conditions\":{\"ref_name\":{\"include\":[$refs_json],\"exclude\":[]}},\"rules\":[{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":$REVIEWS,\"dismiss_stale_reviews_on_push\":true,\"require_code_owner_review\":false,\"require_last_push_approval\":false,\"required_review_thread_resolution\":true}},{\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":true,\"required_status_checks\":[{\"context\":\"$CI_CONTEXT\"}]}}]}"

# --- merge policy --------------------------------------------------------------
policy=$("$GH" api "repos/$REPO" --jq '[.allow_squash_merge, .allow_merge_commit, .allow_rebase_merge, .delete_branch_on_merge, .allow_auto_merge] | map(tostring) | join(",")' 2>/dev/null || echo "")
if [ "$policy" = "true,false,false,true,false" ]; then
  report merge-policy OK "squash only, delete branch on merge, no auto-merge"
elif apply; then
  if "$GH" repo edit "$REPO" --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge --enable-auto-merge=false >/dev/null 2>&1; then
    report merge-policy OK "set squash only, delete branch on merge, no auto-merge (R-512)"
  else
    report merge-policy MISSING "gh repo edit failed"
  fi
else
  report merge-policy MISSING "got [$policy], want squash only, delete on merge, no auto-merge"
fi

# --- alerts and secret scanning ------------------------------------------------
if "$GH" api "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1; then
  report alerts OK "vulnerability alerts on"
elif apply && "$GH" api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1; then
  "$GH" api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null 2>&1 || true
  report alerts OK "vulnerability alerts and security fixes turned on"
else
  report alerts MISSING "vulnerability alerts off"
fi
scan=$("$GH" api "repos/$REPO" --jq '.security_and_analysis.secret_scanning.status // "unknown"' 2>/dev/null || echo unknown)
if [ "$scan" = "enabled" ]; then
  report secret-scan OK "secret scanning on"
elif apply; then
  tmp=$(mktemp); printf '%s' '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' > "$tmp"
  if "$GH" api -X PATCH "repos/$REPO" --input "$tmp" >/dev/null 2>&1; then report secret-scan OK "secret scanning and push protection turned on"; else report secret-scan MISSING "could not enable (private repo without Advanced Security, or not admin)"; fi
  rm -f "$tmp"
else
  report secret-scan MISSING "secret scanning $scan"
fi

# --- greptile ----------------------------------------------------------------------
apps=$("$GH" api "/user/installations" --jq '.installations[].app_slug' 2>/dev/null || true)
if printf '%s\n' "$apps" | grep -qx greptile; then
  report greptile OK "Greptile app installed for $OWNER"
else
  report greptile MISSING "install at https://github.com/apps/greptile/installations/new and grant $REPO (no API for this)"
fi

if [ "$missing" -gt 0 ]; then
  echo "repo-setup: $missing item(s) not at baseline"
  exit 1
fi
echo "repo-setup: $REPO meets the baseline"
