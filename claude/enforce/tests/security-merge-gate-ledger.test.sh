#!/usr/bin/env bash
# Covers: hook:git-workflow-guard, hook:protected-path-guard
# Verifies that the security merge gate (IAN-381, B-10b, rule R-109) checks the
# Security review artefact against the hash recorded at review time, and that
# it refuses a stale local base ref.
#
# The record: enforce/security-review-record.sh <artefact repo-relative path>,
# run from anywhere inside a repository, writes the artefact's git blob at HEAD
# (`git rev-parse HEAD:<path>`, never the working-tree copy) into the untracked
# ledger .claude/security-review-ledger.json at the repository top level. The
# ledger is one JSON object keyed by the full head sha:
#   { "<head sha>": { "path": "<path>", "blob": "<blob oid>",
#                     "recordedAt": "YYYY-MM-DDTHH:MM:SSZ" } }
# The script exits non-zero and writes nothing when the path does not exist at
# HEAD. The ledger is a gate input: protected-path-guard.sh denies a Write tool
# call to it, so the script run through Bash is its only writer.
#
# The check: on a security-touching PR whose `## Security review` names an
# `artefact`, `gh pr merge` is denied with a reason naming R-109 and "recorded
# at review time" when the ledger is missing, holds no entry for the PR head,
# or holds an entry whose path or blob differs from `git rev-parse
# <headRefOid>:<artefact path>`. On any security-touching PR it is also denied
# with R-109 when gh reports no baseRefOid, and with R-109 and a reason naming
# `git fetch` when the local refs/remotes/origin/<baseRefName> differs from the
# baseRefOid gh reports. A matching record with a current base reaches the
# plain R-514 ask.
#
# Each case builds its own throwaway repository: `main` and `origin/main` hold
# a README-only base commit, and a `feature` branch holds two PR commits (the
# first adds app/middleware/cors_config.py and two artefacts with identical
# content under docs/reviews/, the second rewrites the CORS file), with the
# checkout left on `main`. gh is stubbed through CLAUDE_GH_CMD and Semgrep
# through CLAUDE_SEMGREP_CMD, and HOME is a scratch directory throughout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
GUARD="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
RECORD_SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS

failures=0
report_failure() { echo "FAIL security-merge-gate-ledger.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate-ledger.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}

LEDGER_REL=.claude/security-review-ledger.json
ARTEFACT_PATH=docs/reviews/security-review-pr42.json
# A second artefact with the same content, so its blob equals the first one's
# and a record naming it differs from the review in path alone.
OTHER_ARTEFACT_PATH=docs/reviews/security-review-other.json
ARTEFACT_CONTENT='{"findings":[]}'
CLEAN_NOTHING_FOUND='Nothing found: CSRF token check: sources request header X-CSRF-Token, session row: tried empty, null, oversized, mixed case'
STALE_BASE_OID=$(printf 'cafe%.0s' 1 2 3 4 5 6 7 8 9 10)

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
# write_pr_stub <name> <body> <head oid> <base oid>: a gh stand-in answering
# for PR 42 of a same-repository `feature` branch into `main`, headed at
# <head oid>. An empty <base oid> leaves baseRefOid out of the answer.
write_pr_stub() {
  local stub_path="$STUB_DIR/$1" pr_json
  pr_json=$(jq -nc --arg body "$2" --arg head "$3" --arg base "$4" '{
    body: $body, labels: [], commits: [], headRefName: "feature", headRefOid: $head,
    baseRefName: "main", baseRefOid: $base, isCrossRepository: false, url: "https://github.com/example/app/pull/42"}
    | if $base == "" then del(.baseRefOid) else . end')
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

# build_pr_repo <name>: builds the security-touching PR repository described
# in the header. Sets REPO_DIR, REPO_BASE (also the local origin/main), and
# REPO_HEAD.
build_pr_repo() {
  REPO_DIR="$WORK/$1"
  local origin_dir="$WORK/$1-origin.git"
  mkdir -p "$REPO_DIR"
  git init -q "$REPO_DIR" && git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/main
  printf 'Fixture repository %s.\n' "$1" > "$REPO_DIR/README.md"
  git_in "$REPO_DIR" add README.md
  git_in "$REPO_DIR" commit -q -m "chore: base"
  REPO_BASE=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q -b feature
  mkdir -p "$REPO_DIR/app/middleware" "$REPO_DIR/docs/reviews"
  printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
  printf '%s\n' "$ARTEFACT_CONTENT" > "$REPO_DIR/$ARTEFACT_PATH"
  printf '%s\n' "$ARTEFACT_CONTENT" > "$REPO_DIR/$OTHER_ARTEFACT_PATH"
  git_in "$REPO_DIR" add app docs
  git_in "$REPO_DIR" commit -q -m "feat: first PR commit"
  printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
  git_in "$REPO_DIR" add app
  git_in "$REPO_DIR" commit -q -m "fix: second PR commit"
  REPO_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q main
  git init -q --bare "$origin_dir"
  git_in "$REPO_DIR" remote add origin "$origin_dir"
  git_in "$REPO_DIR" push -q origin main feature
  git_in "$REPO_DIR" fetch -q origin
  [ "$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null)" = "$REPO_BASE" ] ||
    { echo "FAIL security-merge-gate-ledger.test.sh: fixture setup could not point origin/main at the base in $1"; exit 1; }
  [ ! -e "$REPO_DIR/$LEDGER_REL" ] ||
    { echo "FAIL security-merge-gate-ledger.test.sh: fixture setup found a ledger before any record in $1"; exit 1; }
}

# run_record <repo> <head> <subdirectory> <path>: runs the record script for
# <path> from <subdirectory> ("." for the top) of a detached checkout of
# <head>, checks `main` back out, and prints the script's exit status.
run_record() {
  local record_status
  git_in "$1" checkout -q --detach "$2"
  (cd "$1/$3" && bash "$RECORD_SCRIPT" "$4" >/dev/null 2>&1)
  record_status=$?
  git_in "$1" checkout -q main
  printf '%s' "$record_status"
}

# security_section <base> <head> <artefact path>: a Security review that clears
# every check older than B-10b: reviewer, model, current range, artefact line
# naming an empty-findings artefact, and a clean Nothing found line.
security_section() {
  printf '## Security review\n\n- reviewer: security-reviewer subagent\n- model: %s\n- range: %.7s..%.7s\n- artefact: %s\n\n%s\n' \
    "$EXPECTED_MODEL" "$1" "$2" "$3" "$CLEAN_NOTHING_FOUND"
}

# pr_body <base> <head> <artefact path>: a PR body holding a summary, a valid
# Codex review, the Security review, and a testing section.
pr_body() {
  printf '## Summary\nWork.\n\n## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-10b.\n\n%s\n\n## Testing\nGreen.\n' \
    "$1" "$2" "$(security_section "$1" "$2" "$3")"
}

# run_merge <stub> <repo> <head>: the hook's JSON output for a merge pinned to
# <head> with --match-head-commit, run from <repo>.
run_merge() {
  jq -nc --arg c "gh pr merge 42 --squash --match-head-commit $3" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
    CLAUDE_GH_CMD="$1" CLAUDE_SEMGREP_CMD="$CLEAN_STUB" "$HOOK" 2>/dev/null
}

# read_decision <output> / read_reason <output>: the decision ("none" when the
# hook printed nothing) and its reason.
read_decision() {
  if [ -z "$1" ]; then echo none; else printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo unreadable; fi
}
read_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

# expect_r109_deny <case> <output> [<phrase>]: the merge is denied, the reason
# names R-109, and, when <phrase> is given, the reason contains it.
expect_r109_deny() {
  local decision reason
  decision=$(read_decision "$2")
  reason=$(read_reason "$2")
  [ "$decision" = deny ] || { report_failure "$1: expected deny, got $decision ($reason)"; return 1; }
  case "$reason" in *R-109*) ;; *) report_failure "$1: deny reason does not name R-109: $reason"; return 1 ;; esac
  [ -z "${3:-}" ] || case "$reason" in *"$3"*) ;; *) report_failure "$1: deny reason does not contain '$3': $reason"; return 1 ;; esac
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

# --- Case a0: the record script writes the ledger shape ----------------------
# Run from the docs/ subdirectory with an uncommitted edit to the artefact, so
# the record must land at the top level and carry the blob at HEAD.
build_pr_repo recorded
REC_DIR="$REPO_DIR" REC_BASE="$REPO_BASE" REC_HEAD="$REPO_HEAD"
REC_BLOB=$(git -C "$REC_DIR" rev-parse "$REC_HEAD:$ARTEFACT_PATH")
git_in "$REC_DIR" checkout -q --detach "$REC_HEAD"
printf '%s\n' '{"findings":[{"id":1,"severity":"LOW"}]}' > "$REC_DIR/$ARTEFACT_PATH"
(cd "$REC_DIR/docs" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1)
RECORD_STATUS=$?
git_in "$REC_DIR" checkout -q -- "$ARTEFACT_PATH"
git_in "$REC_DIR" checkout -q main
[ "$RECORD_STATUS" -eq 0 ] || report_failure "case a0: security-review-record.sh $ARTEFACT_PATH exited $RECORD_STATUS at an existing path"
[ ! -e "$REC_DIR/docs/$LEDGER_REL" ] || report_failure "case a0: the ledger was written under the subdirectory the script ran from, not the repository top level"
if [ -f "$REC_DIR/$LEDGER_REL" ]; then
  jq -e . "$REC_DIR/$LEDGER_REL" >/dev/null 2>&1 || report_failure "case a0: $LEDGER_REL is not JSON"
  [ "$(jq -r --arg h "$REC_HEAD" '.[$h].path // ""' "$REC_DIR/$LEDGER_REL" 2>/dev/null)" = "$ARTEFACT_PATH" ] ||
    report_failure "case a0: ledger .[\"<head>\"].path is not $ARTEFACT_PATH: $(cat "$REC_DIR/$LEDGER_REL")"
  [ "$(jq -r --arg h "$REC_HEAD" '.[$h].blob // ""' "$REC_DIR/$LEDGER_REL" 2>/dev/null)" = "$REC_BLOB" ] ||
    report_failure "case a0: ledger .[\"<head>\"].blob is not the artefact blob at HEAD ($REC_BLOB): $(cat "$REC_DIR/$LEDGER_REL")"
  jq -e --arg h "$REC_HEAD" '.[$h].recordedAt | strings | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$REC_DIR/$LEDGER_REL" >/dev/null 2>&1 ||
    report_failure "case a0: ledger .[\"<head>\"].recordedAt is not a UTC timestamp YYYY-MM-DDTHH:MM:SSZ: $(cat "$REC_DIR/$LEDGER_REL")"
else
  report_failure "case a0: security-review-record.sh wrote no ledger at $LEDGER_REL"
fi

# --- Case a: a matching record and a current base reach the R-514 ask ---------
STUB=$(write_pr_stub casea "$(pr_body "$REC_BASE" "$REC_HEAD" "$ARTEFACT_PATH")" "$REC_HEAD" "$REC_BASE")
expect_r514_ask "case a (artefact recorded at review time, base current)" "$(run_merge "$STUB" "$REC_DIR" "$REC_HEAD")"

# --- Case b: no ledger at all ------------------------------------------------
build_pr_repo unrecorded
STUB=$(write_pr_stub caseb "$(pr_body "$REPO_BASE" "$REPO_HEAD" "$ARTEFACT_PATH")" "$REPO_HEAD" "$REPO_BASE")
expect_r109_deny "case b (no ledger)" "$(run_merge "$STUB" "$REPO_DIR" "$REPO_HEAD")" "recorded at review time"

# --- Case c: recorded at an older head, then the artefact changed -------------
# The review's range and the PR head move to the new commit, so the ledger has
# no entry for the head being merged.
build_pr_repo moved
MOVED_DIR="$REPO_DIR" MOVED_BASE="$REPO_BASE" MOVED_OLD_HEAD="$REPO_HEAD"
[ "$(run_record "$MOVED_DIR" "$MOVED_OLD_HEAD" . "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case c setup: security-review-record.sh could not record $ARTEFACT_PATH at the older head"
git_in "$MOVED_DIR" checkout -q feature
printf '%s\n' '{"findings": [], "note": "edited after the review"}' > "$MOVED_DIR/$ARTEFACT_PATH"
git_in "$MOVED_DIR" add docs
git_in "$MOVED_DIR" commit -q -m "docs: edit the review artefact"
MOVED_HEAD=$(git -C "$MOVED_DIR" rev-parse HEAD)
git_in "$MOVED_DIR" checkout -q main
[ "$MOVED_HEAD" != "$MOVED_OLD_HEAD" ] || report_failure "case c setup: the later PR commit was not created"
STUB=$(write_pr_stub casec "$(pr_body "$MOVED_BASE" "$MOVED_HEAD" "$ARTEFACT_PATH")" "$MOVED_HEAD" "$MOVED_BASE")
expect_r109_deny "case c (ledger has no entry for the new head)" "$(run_merge "$STUB" "$MOVED_DIR" "$MOVED_HEAD")" "recorded at review time"

# --- Case d: the entry for the head records a different blob -----------------
build_pr_repo tampered
[ "$(run_record "$REPO_DIR" "$REPO_HEAD" . "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case d setup: security-review-record.sh could not record $ARTEFACT_PATH"
OTHER_BLOB=$(git -C "$REPO_DIR" rev-parse "$REPO_HEAD:README.md")
if [ -f "$REPO_DIR/$LEDGER_REL" ]; then
  jq --arg h "$REPO_HEAD" --arg b "$OTHER_BLOB" '.[$h].blob = $b' "$REPO_DIR/$LEDGER_REL" > "$WORK/tampered-ledger.json" &&
    cp "$WORK/tampered-ledger.json" "$REPO_DIR/$LEDGER_REL"
else
  mkdir -p "$REPO_DIR/.claude"
  jq -nc --arg h "$REPO_HEAD" --arg p "$ARTEFACT_PATH" --arg b "$OTHER_BLOB" \
    '{($h): {path: $p, blob: $b, recordedAt: "2026-09-26T00:00:00Z"}}' > "$REPO_DIR/$LEDGER_REL"
fi
STUB=$(write_pr_stub cased "$(pr_body "$REPO_BASE" "$REPO_HEAD" "$ARTEFACT_PATH")" "$REPO_HEAD" "$REPO_BASE")
expect_r109_deny "case d (ledger blob differs from the artefact at the head)" "$(run_merge "$STUB" "$REPO_DIR" "$REPO_HEAD")" "recorded at review time"

# --- Case d2: the entry for the head records a different path ----------------
# The other artefact has identical content, so only the path differs.
build_pr_repo other-path
[ "$(run_record "$REPO_DIR" "$REPO_HEAD" . "$OTHER_ARTEFACT_PATH")" = 0 ] ||
  report_failure "case d2 setup: security-review-record.sh could not record $OTHER_ARTEFACT_PATH"
STUB=$(write_pr_stub cased2 "$(pr_body "$REPO_BASE" "$REPO_HEAD" "$ARTEFACT_PATH")" "$REPO_HEAD" "$REPO_BASE")
expect_r109_deny "case d2 (ledger path differs from the review's artefact)" "$(run_merge "$STUB" "$REPO_DIR" "$REPO_HEAD")" "recorded at review time"

# --- Case e: the script refuses a path that does not exist at HEAD -----------
build_pr_repo absent
ABSENT_STATUS=$(run_record "$REPO_DIR" "$REPO_HEAD" . docs/reviews/security-review-absent.json)
[ "$ABSENT_STATUS" != 0 ] || report_failure "case e: security-review-record.sh exited 0 for a path absent at HEAD"
[ ! -e "$REPO_DIR/$LEDGER_REL" ] || report_failure "case e: security-review-record.sh wrote a ledger for a path absent at HEAD"
# A file present only in the working tree is not at HEAD either.
git_in "$REPO_DIR" checkout -q --detach "$REPO_HEAD"
printf '%s\n' "$ARTEFACT_CONTENT" > "$REPO_DIR/docs/reviews/security-review-untracked.json"
(cd "$REPO_DIR" && bash "$RECORD_SCRIPT" docs/reviews/security-review-untracked.json >/dev/null 2>&1)
UNTRACKED_STATUS=$?
rm -f "$REPO_DIR/docs/reviews/security-review-untracked.json"
git_in "$REPO_DIR" checkout -q main
[ "$UNTRACKED_STATUS" != 0 ] || report_failure "case e: security-review-record.sh exited 0 for a path only in the working tree"
[ ! -e "$REPO_DIR/$LEDGER_REL" ] || report_failure "case e: security-review-record.sh wrote a ledger for a path only in the working tree"
# An existing ledger is left byte for byte as it was.
if [ -f "$REC_DIR/$LEDGER_REL" ]; then
  cp "$REC_DIR/$LEDGER_REL" "$WORK/ledger-before.json"
  EXISTING_STATUS=$(run_record "$REC_DIR" "$REC_HEAD" . docs/reviews/security-review-absent.json)
  [ "$EXISTING_STATUS" != 0 ] || report_failure "case e: security-review-record.sh exited 0 for an absent path beside an existing ledger"
  cmp -s "$WORK/ledger-before.json" "$REC_DIR/$LEDGER_REL" ||
    report_failure "case e: security-review-record.sh changed the existing ledger for an absent path"
fi

# --- Case f: the ledger is a gate input the Write tool never writes ----------
guard_decision() {
  local guard_output
  guard_output=$(jq -nc --arg f "$1" --arg d "$REC_DIR" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"{}"}}' | "$GUARD" 2>/dev/null)
  if [ -z "$guard_output" ]; then echo allow; else printf '%s' "$guard_output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi
}
[ "$(guard_decision "$REC_DIR/.claude/review-notes.json")" = allow ] ||
  report_failure "case f control: protected-path-guard denied a Write to an ordinary .claude file, so case f cannot isolate the ledger"
LEDGER_DECISION=$(guard_decision "$REC_DIR/$LEDGER_REL")
[ "$LEDGER_DECISION" = deny ] || report_failure "case f: protected-path-guard answered $LEDGER_DECISION for a Write to $LEDGER_REL, expected deny"

# --- Case g: the local origin/main is behind the base gh reports -------------
STUB=$(write_pr_stub caseg "$(pr_body "$REC_BASE" "$REC_HEAD" "$ARTEFACT_PATH")" "$REC_HEAD" "$STALE_BASE_OID")
expect_r109_deny "case g (baseRefOid differs from the local origin/main)" "$(run_merge "$STUB" "$REC_DIR" "$REC_HEAD")" "git fetch"

# --- Case h: gh reports no baseRefOid ----------------------------------------
STUB=$(write_pr_stub caseh "$(pr_body "$REC_BASE" "$REC_HEAD" "$ARTEFACT_PATH")" "$REC_HEAD" "")
expect_r109_deny "case h (no baseRefOid from gh)" "$(run_merge "$STUB" "$REC_DIR" "$REC_HEAD")"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate-ledger.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate-ledger.test.sh"
