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
#
# Usage: setup.sh <owner/repo> [--check] [--stack node|python|go|ruby]
#                 [--branches main,staging] [--required-reviews N]
# Run from the repository's checkout (local files are written there).
# REPO_SETUP_GH_CMD overrides the gh binary (fixtures stub it).
# Exit: 0 baseline met (or applied); 1 with --check when any item is missing;
# 2 usage; 3 gh unavailable or not authenticated.
set -uo pipefail

GH="${REPO_SETUP_GH_CMD:-gh}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=""; CHECK=0; STACK=""; BRANCHES="main,staging"; REVIEWS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --stack) STACK="${2:-}"; shift 2 ;;
    --branches) BRANCHES="${2:-}"; shift 2 ;;
    --required-reviews) REVIEWS="${2:-0}"; shift 2 ;;
    --*) echo "repo-setup: unknown option $1" >&2; exit 2 ;;
    *) REPO="$1"; shift ;;
  esac
done
if [ -z "$REPO" ]; then
  REPO=$("$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi
printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || { echo "usage: setup.sh <owner/repo> [--check] [--stack s] [--branches a,b] [--required-reviews N]" >&2; exit 2; }
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
report() { printf '%-14s %-8s %s\n' "$1" "$2" "$3"; [ "$2" = "OK" ] || missing=$((missing + 1)); }
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
write_if_absent .github/workflows/ci.yml "template-ci-$STACK.yml" "" ci
write_if_absent .github/dependabot.yml template-dependabot.yml "s/__ECOSYSTEM__/$ECOSYSTEM/" dependabot
write_if_absent .github/pull_request_template.md template-pull-request.md "" pr-template
write_if_absent .gitignore "template-gitignore-$STACK" "" gitignore

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
ensure_ruleset protect-merge "{\"name\":\"protect-merge\",\"target\":\"branch\",\"enforcement\":\"active\",\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"always\"}],\"conditions\":{\"ref_name\":{\"include\":[$refs_json],\"exclude\":[]}},\"rules\":[{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":$REVIEWS,\"dismiss_stale_reviews_on_push\":true,\"require_code_owner_review\":false,\"require_last_push_approval\":false,\"required_review_thread_resolution\":true}},{\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":true,\"required_status_checks\":[{\"context\":\"ci\"}]}}]}"

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
