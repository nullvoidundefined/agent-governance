#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Verifies the hardening of the security merge gate in git-workflow-guard.sh
# (IAN-381, B-9c, rule R-109) found by the R-517 review of PR #145. On a
# security-touching PR, `gh pr merge` is denied with a reason naming R-109 when:
# the Semgrep run inside the security-surface detector outlives
# CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS (the hook must answer within a
# bounded wall time, not wait for Semgrep); the artefact holds a finding id the
# findings table has no row for; the artefact holds findings and the section
# carries no findings table; a table row has the wrong number of cells or an
# unknown status; the body holds two `## Security review` headings; a waived row
# sits beside a downgraded row; a `Nothing found:` line names only a placeholder
# (`none`, `n/a`, `-`) as its tried values; or the merge command does not pin the
# reviewed head with `--match-head-commit <full head sha>`. A fully valid review
# merged with the matching `--match-head-commit` reaches the plain R-514 ask, and
# a PR touching no security surface reaches that ask without the flag (B-14).
#
# The security repository mirrors security-merge-gate-findings.test.sh: `main`
# and `origin/main` hold a README-only base commit, and a `feature` branch holds
# two PR commits (the first adds app/middleware/cors_config.py,
# app/core/settings.py, and the artefact under docs/reviews/; the second
# rewrites the CORS file), with the checkout left on `main`. gh is stubbed
# through CLAUDE_GH_CMD, Semgrep through CLAUDE_SEMGREP_CMD, and HOME is a
# scratch directory throughout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS

failures=0
report_failure() { echo "FAIL security-merge-gate-hardening.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate-hardening.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}

# A Semgrep stand-in reporting a complete clean scan: every target it was given
# is listed under paths.scanned (copied from security-merge-gate.test.sh).
CLEAN_STUB="$WORK/clean-semgrep"
cat > "$CLEAN_STUB" <<'STUB'
#!/bin/sh
skip_next=0
targets=""
for argument in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$argument" in
    --config) skip_next=1 ;;
    --*) ;;
    *) targets="$targets$argument
" ;;
  esac
done
printf '%s' "$targets" | jq -R . | jq -sc '{results: [], errors: [], paths: {scanned: .}}'
exit 0
STUB
chmod +x "$CLEAN_STUB"

# A Semgrep stand-in that hangs for 30 seconds before handing over to the clean
# stub, the way a stuck scan would.
SLOW_STUB="$WORK/slow-semgrep"
printf '#!/bin/sh\nsleep 30\nexec "%s" "$@"\n' "$CLEAN_STUB" > "$SLOW_STUB"
chmod +x "$SLOW_STUB"

STUB_DIR="$WORK/gh-stubs"
mkdir -p "$STUB_DIR"
# write_pr_stub <name> <body> <head oid> <base oid>: a gh stand-in answering
# for PR 42 of a same-repository `feature` branch into `main`, headed at
# <head oid>, whose baseRefOid is <base oid> (the local origin/main, so the
# base the gate reads is current).
write_pr_stub() {
  local stub_path="$STUB_DIR/$1" pr_json
  pr_json=$(jq -nc --arg body "$2" --arg head "$3" --arg base "$4" '{
    body: $body, labels: [], commits: [], headRefName: "feature", headRefOid: $head,
    baseRefName: "main", baseRefOid: $base, isCrossRepository: false, url: "https://github.com/example/app/pull/42"}')
  printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\nexit 0\n' "$pr_json" >"$stub_path"
  chmod +x "$stub_path"
  printf '%s' "$stub_path"
}

# git_in <repo> <git args>...: git with a fixed identity and no signing.
git_in() {
  local repo="$1"
  shift
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1
}

# The artefact every case names: findings 1 to 7, row 7 being HIGH.
MATCHING_ARTEFACT='{"findings":[{"id":1,"severity":"HIGH"},{"id":2,"severity":"MEDIUM"},{"id":3,"severity":"LOW"},{"id":4,"severity":"MEDIUM"},{"id":5,"severity":"LOW"},{"id":6,"severity":"CRITICAL"},{"id":7,"severity":"HIGH"}]}'
MATCHING_ARTEFACT_PATH=docs/reviews/security-review-pr42.json

# Build the security-touching PR repository. Sets REPO_DIR, REPO_BASE,
# REPO_FIRST (the older PR commit, which adds the artefact), and REPO_HEAD.
REPO_DIR="$WORK/sec"
ORIGIN_DIR="$WORK/sec-origin.git"
mkdir -p "$REPO_DIR"
git init -q "$REPO_DIR" && git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/main
printf 'Fixture repository.\n' > "$REPO_DIR/README.md"
git_in "$REPO_DIR" add README.md
git_in "$REPO_DIR" commit -q -m "chore: base"
REPO_BASE=$(git -C "$REPO_DIR" rev-parse HEAD)
git_in "$REPO_DIR" checkout -q -b feature
mkdir -p "$REPO_DIR/app/middleware" "$REPO_DIR/app/core" "$REPO_DIR/docs/reviews"
printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
printf '%s\n' 'DEBUG = False' > "$REPO_DIR/app/core/settings.py"
printf '%s\n' "$MATCHING_ARTEFACT" > "$REPO_DIR/$MATCHING_ARTEFACT_PATH"
git_in "$REPO_DIR" add app docs
git_in "$REPO_DIR" commit -q -m "feat: first PR commit"
REPO_FIRST=$(git -C "$REPO_DIR" rev-parse HEAD)
printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
git_in "$REPO_DIR" add app
git_in "$REPO_DIR" commit -q -m "fix: second PR commit"
REPO_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
git_in "$REPO_DIR" checkout -q main
git init -q --bare "$ORIGIN_DIR"
git_in "$REPO_DIR" remote add origin "$ORIGIN_DIR"
git_in "$REPO_DIR" push -q origin main feature
git_in "$REPO_DIR" fetch -q origin
[ "$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null)" = "$REPO_BASE" ] ||
  { echo "FAIL security-merge-gate-hardening.test.sh: fixture setup could not point origin/main at the base"; exit 1; }

# Build the docs-only PR repository for the B-14 control. Sets DOCS_DIR,
# DOCS_BASE, and DOCS_HEAD.
DOCS_DIR="$WORK/docs"
DOCS_ORIGIN_DIR="$WORK/docs-origin.git"
mkdir -p "$DOCS_DIR"
git init -q "$DOCS_DIR" && git -C "$DOCS_DIR" symbolic-ref HEAD refs/heads/main
printf 'Fixture repository.\n' > "$DOCS_DIR/README.md"
git_in "$DOCS_DIR" add README.md
git_in "$DOCS_DIR" commit -q -m "chore: base"
DOCS_BASE=$(git -C "$DOCS_DIR" rev-parse HEAD)
git_in "$DOCS_DIR" checkout -q -b feature
mkdir -p "$DOCS_DIR/docs"
printf 'Release notes for the next version.\n' > "$DOCS_DIR/docs/notes.md"
git_in "$DOCS_DIR" add docs
git_in "$DOCS_DIR" commit -q -m "docs: notes"
DOCS_HEAD=$(git -C "$DOCS_DIR" rev-parse HEAD)
git_in "$DOCS_DIR" checkout -q main
git init -q --bare "$DOCS_ORIGIN_DIR"
git_in "$DOCS_DIR" remote add origin "$DOCS_ORIGIN_DIR"
git_in "$DOCS_DIR" push -q origin main feature
git_in "$DOCS_DIR" fetch -q origin
[ "$(git -C "$DOCS_DIR" rev-parse origin/main 2>/dev/null)" = "$DOCS_BASE" ] ||
  { echo "FAIL security-merge-gate-hardening.test.sh: fixture setup could not point the docs origin/main at the base"; exit 1; }

# Record the artefact every case names at the PR head in the repository's
# review ledger (.claude/security-review-ledger.json) the way a reviewer does,
# by running enforce/security-review-record.sh from a checkout of the head,
# then check `main` back out. Before the record script exists (B-10b) the step
# is skipped and the older gate alone decides.
RECORD_SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh"
if [ -f "$RECORD_SCRIPT" ]; then
  git_in "$REPO_DIR" checkout -q --detach "$REPO_HEAD"
  (cd "$REPO_DIR" && bash "$RECORD_SCRIPT" "$MATCHING_ARTEFACT_PATH" >/dev/null 2>&1) ||
    report_failure "setup: security-review-record.sh could not record $MATCHING_ARTEFACT_PATH at the PR head"
  git_in "$REPO_DIR" checkout -q main
fi

FIXED_IN_RANGE="\`fixed $REPO_FIRST\`"
CLEAN_NOTHING_FOUND='Nothing found: CSRF token check: sources request header X-CSRF-Token, session row: tried empty, null, oversized, mixed case'
PINNED_MERGE="gh pr merge 42 --squash --match-head-commit $REPO_HEAD"
UNPINNED_MERGE='gh pr merge 42 --squash'

# codex_section <base> <head>: a valid R-517 `## Codex review` section.
codex_section() {
  printf '## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-9c.\n' "$1" "$2"
}

# findings_table <row 7 severity> <row 7 status>: the findings table with
# rows 1 to 6 fixed by the in-range first PR commit, at the artefact's
# severities, and row 7 at the given severity and status.
findings_table() {
  printf '| # | Severity | Control | Source | Worst value tried | Evidence | Fix | Status |\n'
  printf '|---|---|---|---|---|---|---|---|\n'
  printf '| 1 | HIGH | CORS allowlist | env ALLOWED_ORIGINS | * | `app/middleware/cors_config.py:1` | Refuse the wildcard. | %s |\n' "$FIXED_IN_RANGE"
  printf '| 2 | MEDIUM | CORS allowlist | env ALLOWED_ORIGINS | null | `app/middleware/cors_config.py:1` | Refuse null. | %s |\n' "$FIXED_IN_RANGE"
  printf '| 3 | LOW | CORS allowlist | settings default | empty | `app/middleware/cors_config.py:1` | Refuse empty. | %s |\n' "$FIXED_IN_RANGE"
  printf '| 4 | MEDIUM | CORS allowlist | env ALLOWED_ORIGINS | https://app.example.com/path | `app/middleware/cors_config.py:1` | Refuse paths. | %s |\n' "$FIXED_IN_RANGE"
  printf '| 5 | LOW | CORS allowlist | env ALLOWED_ORIGINS | HTTPS://APP.EXAMPLE.COM | `app/middleware/cors_config.py:1` | Normalize case. | %s |\n' "$FIXED_IN_RANGE"
  printf '| 6 | CRITICAL | CORS allowlist | env ALLOWED_ORIGINS | https://user@evil.example | `app/middleware/cors_config.py:1` | Refuse userinfo. | %s |\n' "$FIXED_IN_RANGE"
  printf '| 7 | %s | CORS allowlist | env ALLOWED_ORIGINS | https://evil.example | `app/middleware/cors_config.py:2` | Drop the admin origin. | %s |\n' "$1" "$2"
}

# security_header: the reviewer, model, range, and artefact lines of a
# current Security review on the strongest model.
security_header() {
  printf '## Security review\n\n- reviewer: security-reviewer subagent\n- model: %s\n- range: %.7s..%.7s\n- artefact: %s\n\n' \
    "$EXPECTED_MODEL" "$REPO_BASE" "$REPO_HEAD" "$MATCHING_ARTEFACT_PATH"
}

# valid_section: a Security review that clears every R-109 check.
valid_section() {
  printf '%s\n\n%s\n\n%s\n' "$(security_header)" "$(findings_table HIGH "$FIXED_IN_RANGE")" "$CLEAN_NOTHING_FOUND"
}

# pr_body <security section>: a PR body holding a summary, the Codex review,
# the given Security review section (omitted when empty), and a testing section.
pr_body() {
  printf '## Summary\nWork.\n\n%s\n\n%s\n\n## Testing\nGreen.\n' "$(codex_section "$REPO_BASE" "$REPO_HEAD")" "$1"
}

# run_case <name> <security section> <merge command>: the hook's JSON output
# for <merge command> run from the security repository with that section.
run_case() {
  local stub
  stub=$(write_pr_stub "$1" "$(pr_body "$2")" "$REPO_HEAD" "$REPO_BASE")
  jq -nc --arg c "$3" --arg d "$REPO_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
    CLAUDE_GH_CMD="$stub" CLAUDE_SEMGREP_CMD="$CLEAN_STUB" "$HOOK" 2>/dev/null
}

# read_decision <output> / read_reason <output>: the decision ("none" when the
# hook printed nothing) and its reason.
read_decision() {
  if [ -z "$1" ]; then echo none; else printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo unreadable; fi
}
read_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

# is_row_named <reason> <row>: true when the reason names the row as `#<n>`,
# `row <n>`, `finding <n>`, or `id <n>`, with no further digit after the number.
is_row_named() {
  [[ "$1" =~ (\#|[Rr]ow\ |[Ff]inding\ |[Ii][Dd]\ )$2([^0-9]|$) ]]
}

# expect_r109_deny <case> <output> [<row>]: the merge is denied, the reason
# names R-109, and, when <row> is given, it names that row.
expect_r109_deny() {
  local decision reason
  decision=$(read_decision "$2")
  reason=$(read_reason "$2")
  [ "$decision" = deny ] || { report_failure "$1: expected deny, got $decision ($reason)"; return 1; }
  case "$reason" in *R-109*) ;; *) report_failure "$1: deny reason does not name R-109: $reason"; return 1 ;; esac
  [ -z "${3:-}" ] || is_row_named "$reason" "$3" ||
    { report_failure "$1: deny reason does not name id $3 (as #$3, row $3, finding $3, or id $3): $reason"; return 1; }
}

# expect_r514_ask <case> <output>: the merge reaches R-514's ask and R-109 is silent.
expect_r514_ask() {
  local decision reason
  decision=$(read_decision "$2")
  reason=$(read_reason "$2")
  [ "$decision" = ask ] || { report_failure "$1: expected ask, got $decision ($reason)"; return 1; }
  case "$reason" in *R-514*) ;; *) report_failure "$1: ask reason is not the R-514 merge authorization: $reason" ;; esac
  case "$reason" in *R-109*) report_failure "$1: ask reason names R-109: $reason" ;; esac
}

# Case 1 (detector deadline): Semgrep hangs for 30 seconds and the detector
# deadline is 2 seconds. The PR touches app/core/settings.py, a code file, so
# Semgrep runs, and the body carries no Security review, so the answer is a
# deny; it must arrive well before Semgrep would have finished.
SLOW_GH=$(write_pr_stub case1 "$(pr_body "")" "$REPO_HEAD" "$REPO_BASE")
SLOW_START=$(date +%s)
SLOW_OUT=$(jq -nc --arg c "$PINNED_MERGE" --arg d "$REPO_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
  CLAUDE_GH_CMD="$SLOW_GH" CLAUDE_SEMGREP_CMD="$SLOW_STUB" CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS=2 "$HOOK" 2>/dev/null)
SLOW_ELAPSED=$(($(date +%s) - SLOW_START))
expect_r109_deny "case 1 (Semgrep past the detector deadline)" "$SLOW_OUT"
[ "$SLOW_ELAPSED" -lt 10 ] ||
  report_failure "case 1: a hung Semgrep must be cut off at CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS=2, but the hook took ${SLOW_ELAPSED}s"

# Case 2 (deleted row): the artefact holds ids 1 to 7, and the table has only
# rows 1 to 6, all fixed in range at matching severities.
SECTION="$(security_header)

$(findings_table HIGH "$FIXED_IN_RANGE" | sed '/^| 7 |/d')

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 2 (artefact id 7 has no table row)" "$(run_case case2 "$SECTION" "$PINNED_MERGE")" 7

# Case 3 (table dropped): the artefact holds findings, and the section carries
# only a Nothing found line with values and no table.
SECTION="$(security_header)

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 3 (artefact has findings, section has no table)" "$(run_case case3 "$SECTION" "$PINNED_MERGE")"

# Case 4a (malformed table): row 7 carries 7 cells, its Fix cell missing.
SECTION="$(security_header)

$(findings_table HIGH "$FIXED_IN_RANGE" | sed 's/^\(| 7 | .*\)| Drop the admin origin. |/\1|/')

$CLEAN_NOTHING_FOUND"
case "$SECTION" in *"Drop the admin origin."*) report_failure "case 4a: fixture setup did not remove row 7's Fix cell" ;; esac
expect_r109_deny "case 4a (row 7 has 7 cells)" "$(run_case case4a "$SECTION" "$PINNED_MERGE")"

# Case 4b (malformed table): row 7's status is `closed`, which is not a status.
SECTION="$(security_header)

$(findings_table HIGH '`closed`')

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 4b (row 7 status closed)" "$(run_case case4b "$SECTION" "$PINNED_MERGE")"

# Case 5 (two headings): the body holds two valid `## Security review` sections.
SECTION="$(valid_section)

$(valid_section)"
expect_r109_deny "case 5 (two Security review headings)" "$(run_case case5 "$SECTION" "$PINNED_MERGE")"

# Case 6 (waiver next to a deny): row 6 is waived by the owner and row 7 is
# graded LOW against a HIGH artefact; the downgrade denies, the waiver does
# not soften it into an ask.
SECTION="$(security_header)

$(findings_table LOW "$FIXED_IN_RANGE" | sed 's/^\(| 6 | CRITICAL .*\)| `fixed [0-9a-f]*` |$/\1| `waived by owner 2026-09-26` |/')

$CLEAN_NOTHING_FOUND"
case "$SECTION" in *'waived by owner 2026-09-26'*) ;; *) report_failure "case 6: fixture setup did not waive row 6" ;; esac
expect_r109_deny "case 6 (row 6 waived, row 7 downgraded)" "$(run_case case6 "$SECTION" "$PINNED_MERGE")"

# Case 7 (placeholder values): a Nothing found line whose tried values are a
# placeholder, beside an otherwise valid section.
placeholder_index=0
for placeholder in none n/a -; do
  placeholder_index=$((placeholder_index + 1))
  SECTION="$(valid_section)
Nothing found: CORS: sources env: tried $placeholder"
  expect_r109_deny "case 7 (Nothing found tried $placeholder)" "$(run_case "case7-$placeholder_index" "$SECTION" "$PINNED_MERGE")"
done

# Case 8a (head pinning): a fully valid review merged without
# --match-head-commit is denied, and the reason names the flag.
OUTPUT=$(run_case case8a "$(valid_section)" "$UNPINNED_MERGE")
if expect_r109_deny "case 8a (valid review, merge without --match-head-commit)" "$OUTPUT"; then
  case "$(read_reason "$OUTPUT")" in
    *--match-head-commit*) ;;
    *) report_failure "case 8a: deny reason does not name --match-head-commit: $(read_reason "$OUTPUT")" ;;
  esac
fi

# Case 8b (head pinning): the same merge pinned to the full PR head sha
# reaches the plain R-514 ask.
expect_r514_ask "case 8b (valid review, --match-head-commit at the PR head)" "$(run_case case8b "$(valid_section)" "$PINNED_MERGE")"

# Case 8c (head pinning): a --match-head-commit naming another commit denies.
expect_r109_deny "case 8c (--match-head-commit names another commit)" \
  "$(run_case case8c "$(valid_section)" "gh pr merge 42 --squash --match-head-commit $REPO_FIRST")"

# Case 9 (control, B-14): a docs-only PR merged without --match-head-commit
# reaches the plain R-514 ask.
DOCS_STUB=$(write_pr_stub case9 "$(printf '## Summary\nDocs.\n\n%s\n\n## Testing\nGreen.\n' "$(codex_section "$DOCS_BASE" "$DOCS_HEAD")")" "$DOCS_HEAD" "$DOCS_BASE")
expect_r514_ask "case 9 (no security surface, unpinned merge)" \
  "$(jq -nc --arg c "$UNPINNED_MERGE" --arg d "$DOCS_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
    CLAUDE_GH_CMD="$DOCS_STUB" CLAUDE_SEMGREP_CMD="$CLEAN_STUB" "$HOOK" 2>/dev/null)"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate-hardening.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate-hardening.test.sh"
