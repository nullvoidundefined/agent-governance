#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Verifies that the security merge gate in git-workflow-guard.sh (IAN-381,
# B-10, B-11, B-12, and B-16, rule R-109) reads the findings of a current
# `## Security review` section, not only its reviewer, model, and range lines.
# The section follows the output format of prompts/security-review-prompt.md:
# an `artefact` line naming a repo-relative JSON file at the PR head that holds
# the reviewer's raw output ({"findings":[{"id":1,"severity":"HIGH"}, ...]}),
# a findings table with the columns # | Severity | Control | Source | Worst
# value tried | Evidence | Fix | Status, `Nothing found: <control>: sources
# <...>: tried <...>` lines, or one `No security control in range: <paths>`
# line. On a security-touching PR, `gh pr merge` is denied with a reason naming
# R-109 when a row is `open`, when a row's severity is lower than the
# artefact's severity for the same id, when the artefact cannot be read at the
# PR head, when a `fixed <sha>` names a commit outside base..head, or when a
# Nothing found line names no tried values. A row
# `waived by owner <date>` turns the decision into an ask that names R-109 and
# the waived row. A section that clears every check reaches the plain R-514 ask.
#
# Each case runs against one throwaway repository: `main` and `origin/main`
# hold a README-only base commit, and a `feature` branch holds two PR commits
# (the first adds app/middleware/cors_config.py and the artefact files under
# docs/reviews/, the second rewrites the CORS file), plus an empty third commit
# that becomes the head for cases 8b and 8c, with the checkout left on
# `main`, so the artefact exists only at the PR head and never in the working
# tree. gh is stubbed through CLAUDE_GH_CMD and Semgrep through
# CLAUDE_SEMGREP_CMD, and HOME is a scratch directory throughout.
#
# Origin scheme (B-10f): the repository's `origin` fetch URL is the GitHub
# spelling https://github.com/fixture/sec.git, and its push URL is the bare
# repository beside it, so `git remote get-url origin` prints the GitHub URL
# and a push still lands in the bare repository. The gh stub answers with url
# https://github.com/fixture/sec/pull/42, the same repository.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST

failures=0
report_failure() { echo "FAIL security-merge-gate-findings.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate-findings.test.sh: $MODEL_FILE has no securityReviewModel string"
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

STUB_DIR="$WORK/gh-stubs"
mkdir -p "$STUB_DIR"
# write_pr_stub <name> <body> <head oid>: a gh stand-in answering for PR 42 of
# a same-repository `feature` branch into `main`, headed at <head oid>, whose
# baseRefOid is the base commit the local origin/main holds.
write_pr_stub() {
  local stub_path="$STUB_DIR/$1" pr_json
  pr_json=$(jq -nc --arg body "$2" --arg head "$3" --arg base "$REPO_BASE" '{
    body: $body, labels: [], commits: [], headRefName: "feature", headRefOid: $head,
    baseRefName: "main", baseRefOid: $base, isCrossRepository: false, url: "https://github.com/fixture/sec/pull/42"}')
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

# The artefact every matching case names: findings 1 to 7 with the
# severities the default table carries, row 7 being HIGH.
MATCHING_ARTEFACT='{"findings":[{"id":1,"severity":"HIGH"},{"id":2,"severity":"MEDIUM"},{"id":3,"severity":"LOW"},{"id":4,"severity":"MEDIUM"},{"id":5,"severity":"LOW"},{"id":6,"severity":"CRITICAL"},{"id":7,"severity":"HIGH"}]}'
MATCHING_ARTEFACT_PATH=docs/reviews/security-review-pr42.json
BROKEN_ARTEFACT_PATH=docs/reviews/security-review-broken.json
ABSENT_ARTEFACT_PATH=docs/reviews/security-review-absent.json
# The artefact of a clean review: the reviewer found nothing, so no finding
# needs a table row.
EMPTY_ARTEFACT_PATH=docs/reviews/security-review-empty.json

# Build the security-touching PR repository. Sets REPO_DIR, REPO_BASE,
# REPO_FIRST (the older PR commit, which adds the artefacts), and REPO_HEAD.
REPO_DIR="$WORK/sec"
ORIGIN_DIR="$WORK/sec-origin.git"
mkdir -p "$REPO_DIR"
git init -q "$REPO_DIR" && git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/main
printf 'Fixture repository.\n' > "$REPO_DIR/README.md"
git_in "$REPO_DIR" add README.md
git_in "$REPO_DIR" commit -q -m "chore: base"
REPO_BASE=$(git -C "$REPO_DIR" rev-parse HEAD)
git_in "$REPO_DIR" checkout -q -b feature
mkdir -p "$REPO_DIR/app/middleware" "$REPO_DIR/docs/reviews"
printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
printf '%s\n' "$MATCHING_ARTEFACT" > "$REPO_DIR/$MATCHING_ARTEFACT_PATH"
printf '%s\n' '{"findings":[{"id":1,"severity":' > "$REPO_DIR/$BROKEN_ARTEFACT_PATH"
printf '%s\n' '{"findings":[]}' > "$REPO_DIR/$EMPTY_ARTEFACT_PATH"
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
  { echo "FAIL security-merge-gate-findings.test.sh: fixture setup could not point origin/main at the base"; exit 1; }
git_in "$REPO_DIR" remote set-url origin https://github.com/fixture/sec.git
git_in "$REPO_DIR" remote set-url --push origin "$ORIGIN_DIR"
[ "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" = https://github.com/fixture/sec.git ] ||
  { echo "FAIL security-merge-gate-findings.test.sh: fixture setup could not point origin at https://github.com/fixture/sec.git"; exit 1; }
[ -e "$REPO_DIR/$MATCHING_ARTEFACT_PATH" ] &&
  { echo "FAIL security-merge-gate-findings.test.sh: fixture setup left the artefact in the main working tree"; exit 1; }

# record_artefact <path>: records <path> at the PR head in the repository's
# review ledger ($HOME/.claude/security-review-ledger/<key>.json, B-10e) the way a reviewer does,
# by running enforce/security-review-record.sh from a checkout of the head,
# then checks `main` back out. The ledger is keyed by head and keeps the first
# record for a head, so each record here lands on a distinct head. Before the record script exists
# (B-10b) the step is skipped and the older gate alone decides.
RECORD_SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh"
record_artefact() {
  [ -f "$RECORD_SCRIPT" ] || return 0
  git_in "$REPO_DIR" checkout -q --detach "$REPO_HEAD"
  (cd "$REPO_DIR" && bash "$RECORD_SCRIPT" "$1" >/dev/null 2>&1) ||
    report_failure "setup: security-review-record.sh could not record $1 at the PR head"
  git_in "$REPO_DIR" checkout -q main
}

# Every valid case from 4a to 8a names the matching artefact.
record_artefact "$MATCHING_ARTEFACT_PATH"

IN_RANGE_SHORT=$(printf '%.7s' "$REPO_FIRST")
MISSING_SHA=$(printf 'deadbeef%.0s' 1 2 3 4 5)
CLEAN_NOTHING_FOUND='Nothing found: CSRF token check: sources request header X-CSRF-Token, session row: tried empty, null, oversized, mixed case'

# codex_section: a valid R-517 `## Codex review` section for the PR range.
codex_section() {
  printf '## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-10, B-11, B-12, and B-16.\n' "$REPO_BASE" "$REPO_HEAD"
}

# findings_table <row 7 severity> <row 7 status>: the findings table with
# rows 1 to 6 fixed by the in-range first PR commit, at the artefact's
# severities, and row 7 at the given severity and status.
findings_table() {
  local fixed="\`fixed $REPO_FIRST\`"
  printf '| # | Severity | Control | Source | Worst value tried | Evidence | Fix | Status |\n'
  printf '|---|---|---|---|---|---|---|---|\n'
  printf '| 1 | HIGH | CORS allowlist | env ALLOWED_ORIGINS | * | `app/middleware/cors_config.py:1` | Refuse the wildcard. | %s |\n' "$fixed"
  printf '| 2 | MEDIUM | CORS allowlist | env ALLOWED_ORIGINS | null | `app/middleware/cors_config.py:1` | Refuse null. | %s |\n' "$fixed"
  printf '| 3 | LOW | CORS allowlist | settings default | empty | `app/middleware/cors_config.py:1` | Refuse empty. | %s |\n' "$fixed"
  printf '| 4 | MEDIUM | CORS allowlist | env ALLOWED_ORIGINS | https://app.example.com/path | `app/middleware/cors_config.py:1` | Refuse paths. | %s |\n' "$fixed"
  printf '| 5 | LOW | CORS allowlist | env ALLOWED_ORIGINS | HTTPS://APP.EXAMPLE.COM | `app/middleware/cors_config.py:1` | Normalize case. | %s |\n' "$fixed"
  printf '| 6 | CRITICAL | CORS allowlist | env ALLOWED_ORIGINS | https://user@evil.example | `app/middleware/cors_config.py:1` | Refuse userinfo. | %s |\n' "$fixed"
  printf '| 7 | %s | CORS allowlist | env ALLOWED_ORIGINS | https://evil.example | `app/middleware/cors_config.py:2` | Drop the admin origin. | %s |\n' "$1" "$2"
}

# security_header <artefact path>: the reviewer, model, range, and artefact
# lines of a current Security review on the strongest model.
security_header() {
  printf '## Security review\n\n- reviewer: security-reviewer subagent\n- model: %s\n- range: %.7s..%.7s\n- artefact: %s\n\n' \
    "$EXPECTED_MODEL" "$REPO_BASE" "$REPO_HEAD" "$1"
}

# pr_body <security section>: a PR body holding a summary, the Codex review,
# the given Security review section, and a testing section.
pr_body() {
  printf '## Summary\nWork.\n\n%s\n\n%s\n\n## Testing\nGreen.\n' "$(codex_section)" "$1"
}

# run_case <name> <security section> [<merge command>]: the hook's JSON output
# for <merge command> (default `gh pr merge 42 --squash`) run from the
# repository with that section.
run_case() {
  local stub
  stub=$(write_pr_stub "$1" "$(pr_body "$2")" "$REPO_HEAD")
  jq -nc --arg c "${3:-gh pr merge 42 --squash}" --arg d "$REPO_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
    CLAUDE_GH_CMD="$stub" CLAUDE_SEMGREP_CMD="$CLEAN_STUB" "$HOOK" 2>/dev/null
}

# read_decision <output> / read_reason <output>: the decision ("none" when the
# hook printed nothing) and its reason.
read_decision() {
  if [ -z "$1" ]; then echo none; else printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo unreadable; fi
}
read_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

# is_row_named <reason> <row>: true when the reason names the row as `#<n>`,
# `row <n>`, or `finding <n>`, with no further digit after the number.
is_row_named() {
  [[ "$1" =~ (\#|[Rr]ow\ |[Ff]inding\ )$2([^0-9]|$) ]]
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
    report_failure "$1: deny reason does not name row $3 (as #$3, row $3, or finding $3): $reason"
}

# expect_waiver_ask <case> <output> <row>: the merge asks, and the reason
# names R-109 and the waived row, so the owner confirms the waiver.
expect_waiver_ask() {
  local decision reason
  decision=$(read_decision "$2")
  reason=$(read_reason "$2")
  [ "$decision" = ask ] || { report_failure "$1: expected ask, got $decision ($reason)"; return 1; }
  case "$reason" in *R-109*) ;; *) report_failure "$1: ask reason does not name R-109: $reason" ;; esac
  is_row_named "$reason" "$3" ||
    report_failure "$1: ask reason does not name waived row $3 (as #$3, row $3, or finding $3): $reason"
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

FIXED_IN_RANGE="\`fixed $REPO_FIRST\`"
# The merge command of every case that should clear R-109: it pins the
# reviewed head with --match-head-commit.
PINNED_MERGE="gh pr merge 42 --squash --match-head-commit $REPO_HEAD"

# Case 1: row 7 is still open.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH '`open`')

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 1 (row 7 open)" "$(run_case case1 "$SECTION")" 7

# Case 1b: an open row denies even when another row is waived.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH '`waived by owner 2026-09-26`' | sed 's/^| 6 | CRITICAL \(.*\)| `fixed [0-9a-f]*` |$/| 6 | CRITICAL \1| `open` |/')

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 1b (row 6 open, row 7 waived)" "$(run_case case1b "$SECTION")" 6

# Case 2 (B-10): row 7 is graded LOW in the table but HIGH in the artefact.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table LOW "$FIXED_IN_RANGE")

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 2 (row 7 downgraded from HIGH to LOW)" "$(run_case case2 "$SECTION")"

# Case 3a (fail closed): the artefact line names a file absent at the PR head.
SECTION="$(security_header "$ABSENT_ARTEFACT_PATH")

$(findings_table HIGH "$FIXED_IN_RANGE")

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 3a (artefact missing at the PR head)" "$(run_case case3a "$SECTION")"

# Case 3b (fail closed): the artefact exists at the PR head but is not JSON.
SECTION="$(security_header "$BROKEN_ARTEFACT_PATH")

$(findings_table HIGH "$FIXED_IN_RANGE")

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 3b (artefact unreadable)" "$(run_case case3b "$SECTION")"

# Case 3c (fail closed): the table has rows and the section has no artefact line.
SECTION="$(printf '## Security review\n\n- reviewer: security-reviewer subagent\n- model: %s\n- range: %.7s..%.7s\n\n' "$EXPECTED_MODEL" "$REPO_BASE" "$REPO_HEAD")

$(findings_table HIGH "$FIXED_IN_RANGE")

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 3c (no artefact line)" "$(run_case case3c "$SECTION")"

# Case 4a (B-11): row 7 fixed by the in-range first PR commit, written as a
# short sha; R-109 is satisfied and the R-514 ask follows.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH "\`fixed $IN_RANGE_SHORT\`")

$CLEAN_NOTHING_FOUND"
expect_r514_ask "case 4a (fixed by an in-range short sha)" "$(run_case case4a "$SECTION" "$PINNED_MERGE")"

# Case 4b (B-11): row 7 "fixed" by the base commit, which is outside base..head.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH "\`fixed $REPO_BASE\`")

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 4b (fixed by the base commit, outside the range)" "$(run_case case4b "$SECTION")" 7

# Case 4c (B-11): row 7 "fixed" by a sha that does not exist.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH "\`fixed $MISSING_SHA\`")

$CLEAN_NOTHING_FOUND"
expect_r109_deny "case 4c (fixed by a nonexistent sha)" "$(run_case case4c "$SECTION")" 7

# Case 5 (B-12): row 7 waived by the owner; the gate asks and names the row.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH '`waived by owner 2026-09-26`')

$CLEAN_NOTHING_FOUND"
expect_waiver_ask "case 5 (row 7 waived by owner)" "$(run_case case5 "$SECTION" "$PINNED_MERGE")" 7

# Case 6a (B-16): a Nothing found line with no values after `tried`, beside a
# fully fixed table and a valid Nothing found line.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH "$FIXED_IN_RANGE")

$CLEAN_NOTHING_FOUND
Nothing found: CORS: sources env: tried"
expect_r109_deny "case 6a (Nothing found line names no tried values)" "$(run_case case6a "$SECTION")"

# Case 6b (B-16): the only record is a Nothing found line with no values.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

Nothing found: CORS: sources env: tried"
expect_r109_deny "case 6b (sole Nothing found line names no tried values)" "$(run_case case6b "$SECTION")"

# Case 7 (empty review denies) moves to a follow-up slice after case 4 of security-merge-gate.test.sh is changed to a clean `Nothing found:` line.

# Case 8a (control): every row fixed in range at the artefact's severities,
# a clean Nothing found line, and a matching artefact: the plain R-514 ask.
SECTION="$(security_header "$MATCHING_ARTEFACT_PATH")

$(findings_table HIGH "$FIXED_IN_RANGE")

$CLEAN_NOTHING_FOUND"
expect_r514_ask "case 8a (all fixed in range, clean Nothing found)" "$(run_case case8a "$SECTION" "$PINNED_MERGE")"

# Case 8b (control): an artefact with no findings and only clean Nothing
# found lines with values. Cases 8b and 8c name the empty artefact, and the
# ledger keeps the first record for a head, so an empty third PR commit becomes
# the PR head and the empty artefact is recorded there.
git_in "$REPO_DIR" checkout -q feature
git_in "$REPO_DIR" commit -q --allow-empty -m "docs: empty-findings review"
EMPTY_REVIEW_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
git_in "$REPO_DIR" push -q origin feature
git_in "$REPO_DIR" checkout -q main
[ "$EMPTY_REVIEW_HEAD" != "$REPO_HEAD" ] || report_failure "case 8b setup: the third PR commit was not created"
REPO_HEAD="$EMPTY_REVIEW_HEAD"
PINNED_MERGE="gh pr merge 42 --squash --match-head-commit $REPO_HEAD"
record_artefact "$EMPTY_ARTEFACT_PATH"
SECTION="$(security_header "$EMPTY_ARTEFACT_PATH")

$CLEAN_NOTHING_FOUND
Nothing found: CORS allowlist: sources env ALLOWED_ORIGINS, settings default: tried *, null, empty, https://user@evil.example"
expect_r514_ask "case 8b (empty artefact, clean Nothing found lines only)" "$(run_case case8b "$SECTION" "$PINNED_MERGE")"

# Case 8c (control): an artefact with no findings, and the range holds no
# security control.
SECTION="$(security_header "$EMPTY_ARTEFACT_PATH")

No security control in range: app/middleware/cors_config.py, docs/reviews/security-review-pr42.json, docs/reviews/security-review-empty.json"
expect_r514_ask "case 8c (empty artefact, No security control in range)" "$(run_case case8c "$SECTION" "$PINNED_MERGE")"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate-findings.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate-findings.test.sh"
