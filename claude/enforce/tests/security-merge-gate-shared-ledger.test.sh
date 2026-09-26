#!/usr/bin/env bash
# Covers: hook:git-workflow-guard, hook:protected-path-guard
# Verifies that the Security review ledger (IAN-381, B-10e, rule R-109) lives
# outside the checkout, is shared by every worktree and clone of a repository,
# and is guarded against being written, deleted, or moved by a session.
#
# The location: enforce/security-review-record.sh <artefact path> writes to
# $HOME/.claude/security-review-ledger/<key>.json, where <key> is the sha256 hex
# digest of the repository's `git remote get-url origin` output with its
# trailing newline removed (`printf '%s' "$url" | shasum -a 256`). The JSON
# shape is unchanged: one object keyed by the full head sha, each entry
# {path, blob, recordedAt}. The script exits non-zero and writes nothing when
# the repository has no `origin`, and the first record for a head stands, so a
# second record for the same head from another worktree or a clone of the same
# origin is refused and the shared ledger stays byte for byte as it was.
#
# The gate: hooks/git-workflow-guard.sh reads the ledger from the same place,
# keyed by the merge checkout's `origin` URL, and denies `gh pr merge` with a
# reason naming R-109 and "recorded at review time" when the checkout has no
# `origin` or the ledger holds no matching record. The old in-checkout
# .claude/security-review-ledger.json is never read, so a matching record left
# only there denies.
#
# The guard: hooks/protected-path-guard.sh denies a Write tool call to any file
# in $HOME/.claude/security-review-ledger/ and a Bash rm, rm -rf, mv, cp,
# redirection, or find -delete aimed at that directory or a file in it, with
# the path written literally or through `~`, while running the record script
# through Bash is allowed. The guard has no rule that treats deleting an
# ancestor directory as deleting what it holds, so `rm -rf $HOME/.claude` is
# not asserted here.
#
# Each case builds its own throwaway repository: `main` and `origin/main` hold
# a README-only base commit, and a `feature` branch holds two PR commits (the
# first adds app/middleware/cors_config.py and two artefacts with identical
# content under docs/reviews/, the second rewrites the CORS file), with the
# checkout left on `main` and `origin` a bare repository beside it. gh is
# stubbed through CLAUDE_GH_CMD and Semgrep through CLAUDE_SEMGREP_CMD, and
# HOME is a scratch directory throughout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
GUARD="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
RECORD_SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS

failures=0
report_failure() { echo "FAIL security-merge-gate-shared-ledger.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
# The scratch home every hook and the record script run under; the ledger
# paths below are spelled from it, never from the live install.
SCRATCH_HOME="$WORK/home"
export HOME="$SCRATCH_HOME"
mkdir -p "$SCRATCH_HOME"
export GIT_CONFIG_NOSYSTEM=1

EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate-shared-ledger.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}

LEDGER_DIR="$SCRATCH_HOME/.claude/security-review-ledger"
OLD_LEDGER_REL=.claude/security-review-ledger.json
ARTEFACT_PATH=docs/reviews/security-review-pr42.json
# A second artefact with the same content, so a record naming it differs from
# the first in path alone.
OTHER_ARTEFACT_PATH=docs/reviews/security-review-other.json
ARTEFACT_CONTENT='{"findings":[]}'
CLEAN_NOTHING_FOUND='Nothing found: CSRF token check: sources request header X-CSRF-Token, session row: tried empty, null, oversized, mixed case'

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
# <head oid>, whose baseRefOid is <base oid>.
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

# ledger_path_for <repo>: the shared ledger file for <repo>, keyed by the
# sha256 hex of its `origin` URL; empty when the repository has no origin.
ledger_path_for() {
  local origin_url
  origin_url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  printf '%s/%s.json' "$LEDGER_DIR" "$(printf '%s' "$origin_url" | shasum -a 256 | awk '{print $1}')"
}

# build_pr_repo <name>: builds the security-touching PR repository described
# in the header. Sets REPO_DIR, REPO_ORIGIN, REPO_BASE (also the local
# origin/main), REPO_FIRST, REPO_HEAD, and REPO_LEDGER.
build_pr_repo() {
  REPO_DIR="$WORK/$1"
  REPO_ORIGIN="$WORK/$1-origin.git"
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
  REPO_FIRST=$(git -C "$REPO_DIR" rev-parse HEAD)
  printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
  git_in "$REPO_DIR" add app
  git_in "$REPO_DIR" commit -q -m "fix: second PR commit"
  REPO_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q main
  git init -q --bare "$REPO_ORIGIN"
  git_in "$REPO_DIR" remote add origin "$REPO_ORIGIN"
  git_in "$REPO_DIR" push -q origin main feature
  git_in "$REPO_DIR" fetch -q origin
  [ "$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null)" = "$REPO_BASE" ] ||
    { echo "FAIL security-merge-gate-shared-ledger.test.sh: fixture setup could not point origin/main at the base in $1"; exit 1; }
  REPO_LEDGER=$(ledger_path_for "$REPO_DIR")
  [ -n "$REPO_LEDGER" ] && [ ! -e "$REPO_LEDGER" ] ||
    { echo "FAIL security-merge-gate-shared-ledger.test.sh: fixture setup found a shared ledger before any record in $1"; exit 1; }
}

# run_record <checkout> <head> <path> [<subdirectory>]: runs the record script
# for <path> from <subdirectory> ("." by default) of <checkout> with <head>
# detached, restores the branch or commit it had before, and prints the
# script's exit status.
run_record() {
  local record_status previous_ref
  previous_ref=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$1" rev-parse HEAD)
  git_in "$1" checkout -q --detach "$2"
  (cd "$1/${4:-.}" && bash "$RECORD_SCRIPT" "$3" >/dev/null 2>&1)
  record_status=$?
  git_in "$1" checkout -q "$previous_ref"
  printf '%s' "$record_status"
}

# pr_body <base> <head> <artefact path>: a PR body holding a summary, a valid
# Codex review, a Security review that clears every check older than B-10e
# (reviewer, model, current range, an artefact line, a clean Nothing found
# line), and a testing section.
pr_body() {
  printf '## Summary\nWork.\n\n## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-10e.\n\n## Security review\n\n- reviewer: security-reviewer subagent\n- model: %s\n- range: %.7s..%.7s\n- artefact: %s\n\n%s\n\n## Testing\nGreen.\n' \
    "$1" "$2" "$EXPECTED_MODEL" "$1" "$2" "$3" "$CLEAN_NOTHING_FOUND"
}

# run_merge <stub> <checkout> <head>: the hook's JSON output for a merge pinned
# to <head> with --match-head-commit, run from <checkout>.
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

# --- Case 1: the record script writes the shared ledger ------------------------
# Moved from security-merge-gate-ledger.test.sh case a0. Run from the docs/
# subdirectory with an uncommitted edit to the artefact, so the record must be
# keyed by the repository's origin and carry the blob at HEAD.
build_pr_repo recorded
REC_DIR="$REPO_DIR" REC_BASE="$REPO_BASE" REC_HEAD="$REPO_HEAD" REC_LEDGER="$REPO_LEDGER"
REC_BLOB=$(git -C "$REC_DIR" rev-parse "$REC_HEAD:$ARTEFACT_PATH")
git_in "$REC_DIR" checkout -q --detach "$REC_HEAD"
printf '%s\n' '{"findings":[{"id":1,"severity":"LOW"}]}' > "$REC_DIR/$ARTEFACT_PATH"
(cd "$REC_DIR/docs" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1)
RECORD_STATUS=$?
git_in "$REC_DIR" checkout -q -- "$ARTEFACT_PATH"
git_in "$REC_DIR" checkout -q main
[ "$RECORD_STATUS" -eq 0 ] || report_failure "case 1: security-review-record.sh $ARTEFACT_PATH exited $RECORD_STATUS at an existing path"
if [ -f "$REC_LEDGER" ]; then
  jq -e 'type == "object"' "$REC_LEDGER" >/dev/null 2>&1 || report_failure "case 1: the shared ledger is not a JSON object: $(cat "$REC_LEDGER")"
  [ "$(jq -r --arg h "$REC_HEAD" '.[$h].path // ""' "$REC_LEDGER" 2>/dev/null)" = "$ARTEFACT_PATH" ] ||
    report_failure "case 1: shared ledger .[\"<head>\"].path is not $ARTEFACT_PATH: $(cat "$REC_LEDGER")"
  [ "$(jq -r --arg h "$REC_HEAD" '.[$h].blob // ""' "$REC_LEDGER" 2>/dev/null)" = "$REC_BLOB" ] ||
    report_failure "case 1: shared ledger .[\"<head>\"].blob is not the artefact blob at HEAD ($REC_BLOB): $(cat "$REC_LEDGER")"
  jq -e --arg h "$REC_HEAD" '.[$h].recordedAt | strings | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$REC_LEDGER" >/dev/null 2>&1 ||
    report_failure "case 1: shared ledger .[\"<head>\"].recordedAt is not a UTC timestamp YYYY-MM-DDTHH:MM:SSZ: $(cat "$REC_LEDGER")"
else
  report_failure "case 1: security-review-record.sh wrote no shared ledger at <scratch home>/.claude/security-review-ledger/<sha256 of the origin URL>.json ($REC_LEDGER)"
fi
[ ! -e "$REC_DIR/$OLD_LEDGER_REL" ] || report_failure "case 1: security-review-record.sh still wrote the in-checkout ledger $OLD_LEDGER_REL"
[ ! -e "$REC_DIR/docs/$OLD_LEDGER_REL" ] || report_failure "case 1: security-review-record.sh wrote a ledger under the subdirectory it ran from"

# Control: the record just made reaches the R-514 ask.
STUB=$(write_pr_stub case1 "$(pr_body "$REC_BASE" "$REC_HEAD" "$ARTEFACT_PATH")" "$REC_HEAD" "$REC_BASE")
expect_r514_ask "case 1 control (recorded in the shared ledger, base current)" "$(run_merge "$STUB" "$REC_DIR" "$REC_HEAD")"

# --- Case 2: the record script refuses a repository with no origin -------------
# A HOME of its own, so any file the script writes under it is visible.
build_pr_repo no-origin-record
NOREC_DIR="$REPO_DIR" NOREC_HEAD="$REPO_HEAD"
git_in "$NOREC_DIR" remote remove origin
NOREC_HOME="$WORK/home-no-origin"
mkdir -p "$NOREC_HOME"
git_in "$NOREC_DIR" checkout -q --detach "$NOREC_HEAD"
(cd "$NOREC_DIR" && HOME="$NOREC_HOME" bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1)
NOREC_STATUS=$?
git_in "$NOREC_DIR" checkout -q main
[ "$NOREC_STATUS" != 0 ] || report_failure "case 2: security-review-record.sh exited 0 in a repository with no origin"
NOREC_WRITTEN=$(find "$NOREC_HOME" -type f 2>/dev/null)
[ -z "$NOREC_WRITTEN" ] || report_failure "case 2: security-review-record.sh wrote under HOME in a repository with no origin: $NOREC_WRITTEN"
[ ! -e "$NOREC_DIR/$OLD_LEDGER_REL" ] || report_failure "case 2: security-review-record.sh wrote $OLD_LEDGER_REL in a repository with no origin"

# --- Case 3: the gate denies a merge checkout with no origin -------------------
# The record is made while origin exists, then origin is removed; the local
# refs/remotes/origin/main is put back so the base check still passes and only
# the missing origin can decide.
build_pr_repo no-origin-merge
NOMERGE_DIR="$REPO_DIR" NOMERGE_BASE="$REPO_BASE" NOMERGE_HEAD="$REPO_HEAD"
[ "$(run_record "$NOMERGE_DIR" "$NOMERGE_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case 3 setup: security-review-record.sh could not record $ARTEFACT_PATH while origin existed"
git_in "$NOMERGE_DIR" remote remove origin
git_in "$NOMERGE_DIR" update-ref refs/remotes/origin/main "$NOMERGE_BASE"
[ -z "$(git -C "$NOMERGE_DIR" remote)" ] || report_failure "case 3 setup: the repository still has a remote"
STUB=$(write_pr_stub case3 "$(pr_body "$NOMERGE_BASE" "$NOMERGE_HEAD" "$ARTEFACT_PATH")" "$NOMERGE_HEAD" "$NOMERGE_BASE")
expect_r109_deny "case 3 (merge checkout has no origin)" "$(run_merge "$STUB" "$NOMERGE_DIR" "$NOMERGE_HEAD")" "recorded at review time"

# --- Case 4: a matching record left only at the old in-checkout path -----------
build_pr_repo old-path
OLD_DIR="$REPO_DIR" OLD_BASE="$REPO_BASE" OLD_HEAD="$REPO_HEAD" OLD_SHARED_LEDGER="$REPO_LEDGER"
OLD_BLOB=$(git -C "$OLD_DIR" rev-parse "$OLD_HEAD:$ARTEFACT_PATH")
mkdir -p "$OLD_DIR/.claude"
jq -nc --arg h "$OLD_HEAD" --arg p "$ARTEFACT_PATH" --arg b "$OLD_BLOB" \
  '{($h): {path: $p, blob: $b, recordedAt: "2026-09-26T00:00:00Z"}}' > "$OLD_DIR/$OLD_LEDGER_REL"
[ ! -e "$OLD_SHARED_LEDGER" ] || report_failure "case 4 setup: a shared ledger exists for the old-path repository"
STUB=$(write_pr_stub case4 "$(pr_body "$OLD_BASE" "$OLD_HEAD" "$ARTEFACT_PATH")" "$OLD_HEAD" "$OLD_BASE")
expect_r109_deny "case 4 (matching record only at the old $OLD_LEDGER_REL)" "$(run_merge "$STUB" "$OLD_DIR" "$OLD_HEAD")" "recorded at review time"

# --- Case 5: one ledger for every worktree and clone ---------------------------
# Record in worktree 1, merge from worktree 2: the record is found.
build_pr_repo shared
SHARED_DIR="$REPO_DIR" SHARED_ORIGIN="$REPO_ORIGIN" SHARED_BASE="$REPO_BASE" SHARED_HEAD="$REPO_HEAD" SHARED_LEDGER="$REPO_LEDGER"
WORKTREE_ONE="$WORK/shared-worktree-one"
WORKTREE_TWO="$WORK/shared-worktree-two"
git_in "$SHARED_DIR" worktree add -q --detach "$WORKTREE_ONE" "$SHARED_BASE"
git_in "$SHARED_DIR" worktree add -q -b worktree-two-main "$WORKTREE_TWO" "$SHARED_BASE"
[ -d "$WORKTREE_ONE" ] && [ -d "$WORKTREE_TWO" ] ||
  { echo "FAIL security-merge-gate-shared-ledger.test.sh: fixture setup could not add the two worktrees"; exit 1; }
[ "$(run_record "$WORKTREE_ONE" "$SHARED_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case 5a setup: security-review-record.sh could not record $ARTEFACT_PATH in worktree 1"
STUB=$(write_pr_stub case5 "$(pr_body "$SHARED_BASE" "$SHARED_HEAD" "$ARTEFACT_PATH")" "$SHARED_HEAD" "$SHARED_BASE")
expect_r514_ask "case 5a (recorded in worktree 1, merged from worktree 2)" "$(run_merge "$STUB" "$WORKTREE_TWO" "$SHARED_HEAD")"
[ ! -e "$WORKTREE_ONE/$OLD_LEDGER_REL" ] || report_failure "case 5a: the record landed in worktree 1's own $OLD_LEDGER_REL"

# A different artefact for the same head, from worktree 2, is refused.
if [ -f "$SHARED_LEDGER" ]; then
  cp "$SHARED_LEDGER" "$WORK/shared-ledger-before.json"
  WORKTREE_TWO_STATUS=$(run_record "$WORKTREE_TWO" "$SHARED_HEAD" "$OTHER_ARTEFACT_PATH")
  [ "$WORKTREE_TWO_STATUS" != 0 ] ||
    report_failure "case 5b: security-review-record.sh exited 0 recording another artefact for head $(printf '%.7s' "$SHARED_HEAD") from worktree 2"
  cmp -s "$WORK/shared-ledger-before.json" "$SHARED_LEDGER" ||
    report_failure "case 5b: the shared ledger changed when worktree 2 recorded the same head again: $(cat "$SHARED_LEDGER")"
  [ ! -e "$WORKTREE_TWO/$OLD_LEDGER_REL" ] || report_failure "case 5b: worktree 2 wrote its own $OLD_LEDGER_REL"

  # A clone of the same origin shares the ledger too.
  CLONE_DIR="$WORK/shared-clone"
  git clone -q "$SHARED_ORIGIN" "$CLONE_DIR" >/dev/null 2>&1
  [ "$(ledger_path_for "$CLONE_DIR")" = "$SHARED_LEDGER" ] ||
    report_failure "case 5c setup: the clone's origin URL does not key the same ledger"
  CLONE_STATUS=$(run_record "$CLONE_DIR" "$SHARED_HEAD" "$OTHER_ARTEFACT_PATH")
  [ "$CLONE_STATUS" != 0 ] ||
    report_failure "case 5c: security-review-record.sh exited 0 recording another artefact for head $(printf '%.7s' "$SHARED_HEAD") from a clone"
  cmp -s "$WORK/shared-ledger-before.json" "$SHARED_LEDGER" ||
    report_failure "case 5c: the shared ledger changed when a clone recorded the same head again: $(cat "$SHARED_LEDGER")"
  [ ! -e "$CLONE_DIR/$OLD_LEDGER_REL" ] || report_failure "case 5c: the clone wrote its own $OLD_LEDGER_REL"

  # The first record still decides, from worktree 2.
  expect_r514_ask "case 5d (first record still decides after refused second records)" "$(run_merge "$STUB" "$WORKTREE_TWO" "$SHARED_HEAD")"
else
  report_failure "case 5 setup: recording in worktree 1 wrote no shared ledger at $SHARED_LEDGER"
fi

# --- Case 6: the first record for a head stands (moved from review-fixes B) -----
build_pr_repo first-wins
FIRST_DIR="$REPO_DIR" FIRST_BASE="$REPO_BASE" FIRST_FIRST="$REPO_FIRST" FIRST_HEAD="$REPO_HEAD" FIRST_LEDGER="$REPO_LEDGER"
[ "$(run_record "$FIRST_DIR" "$FIRST_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case 6 setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
if [ -f "$FIRST_LEDGER" ]; then
  cp "$FIRST_LEDGER" "$WORK/first-ledger-before.json"
  HEAD_ENTRY_BEFORE=$(jq -c --arg h "$FIRST_HEAD" '.[$h]' "$FIRST_LEDGER" 2>/dev/null)
  # 6a: a second record for the same head, naming another path, is refused.
  SAME_HEAD_STATUS=$(run_record "$FIRST_DIR" "$FIRST_HEAD" "$OTHER_ARTEFACT_PATH")
  [ "$SAME_HEAD_STATUS" != 0 ] ||
    report_failure "case 6a: security-review-record.sh exited 0 when replacing the ledger entry for head $(printf '%.7s' "$FIRST_HEAD")"
  cmp -s "$WORK/first-ledger-before.json" "$FIRST_LEDGER" ||
    report_failure "case 6a: the shared ledger changed when a second record for the same head was refused: $(cat "$FIRST_LEDGER")"
  STUB=$(write_pr_stub case6 "$(pr_body "$FIRST_BASE" "$FIRST_HEAD" "$ARTEFACT_PATH")" "$FIRST_HEAD" "$FIRST_BASE")
  expect_r514_ask "case 6a (first record still decides after a refused second record)" "$(run_merge "$STUB" "$FIRST_DIR" "$FIRST_HEAD")"
  # 6b: a record for a different head succeeds and keeps the earlier entry.
  OTHER_HEAD_STATUS=$(run_record "$FIRST_DIR" "$FIRST_FIRST" "$OTHER_ARTEFACT_PATH")
  [ "$OTHER_HEAD_STATUS" = 0 ] ||
    report_failure "case 6b: security-review-record.sh exited $OTHER_HEAD_STATUS recording a different head"
  [ "$(jq -r --arg h "$FIRST_FIRST" '.[$h].path // ""' "$FIRST_LEDGER" 2>/dev/null)" = "$OTHER_ARTEFACT_PATH" ] ||
    report_failure "case 6b: the shared ledger has no entry for the different head naming $OTHER_ARTEFACT_PATH: $(cat "$FIRST_LEDGER")"
  [ "$(jq -c --arg h "$FIRST_HEAD" '.[$h]' "$FIRST_LEDGER" 2>/dev/null)" = "$HEAD_ENTRY_BEFORE" ] ||
    report_failure "case 6b: recording a different head changed the earlier head's entry: $(cat "$FIRST_LEDGER")"
else
  report_failure "case 6 setup: security-review-record.sh wrote no shared ledger at $FIRST_LEDGER"
fi

# --- Case 7: the guard keeps sessions off the shared ledger --------------------
# Every call runs from the recorded repository; the ledger key is that
# repository's, so the file named exists.
LEDGER_KEY_FILE="$REC_LEDGER"
LEDGER_KEY_NAME="${REC_LEDGER##*/}"

# guard_write_decision <file path>: the guard's decision for a Write tool call
# to <file path>, "allow" when silent.
guard_write_decision() {
  local guard_output
  guard_output=$(jq -nc --arg f "$1" --arg d "$REC_DIR" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"{}"}}' | "$GUARD" 2>/dev/null)
  if [ -z "$guard_output" ]; then echo allow; else printf '%s' "$guard_output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi
}

# guard_bash_decision <command>: the guard's decision for a Bash call running
# <command>, "allow" when silent.
guard_bash_decision() {
  local guard_output
  guard_output=$(jq -nc --arg c "$1" --arg d "$REC_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$GUARD" 2>/dev/null)
  if [ -z "$guard_output" ]; then echo allow; else printf '%s' "$guard_output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi
}

# expect_guard <want> <case> <decision>: the decision is <want>, or, for want
# "allow", anything but deny.
expect_guard() {
  if [ "$1" = allow ]; then
    [ "$3" != deny ] || report_failure "$2: expected no deny, got deny"
  else
    [ "$3" = "$1" ] || report_failure "$2: expected $1, got $3"
  fi
}

# Control: a Write to an ordinary file under $HOME/.claude is not denied, so
# the denies below come from the ledger directory alone.
expect_guard allow "case 7 control (Write to another file under the scratch home's .claude)" "$(guard_write_decision "$SCRATCH_HOME/.claude/review-notes.json")"
expect_guard deny "case 7a (Write to the shared ledger file)" "$(guard_write_decision "$LEDGER_KEY_FILE")"
expect_guard deny "case 7b (Write to a new file in the ledger directory)" "$(guard_write_decision "$LEDGER_DIR/any-other-key.json")"
expect_guard deny "case 7c (rm -rf the ledger directory)" "$(guard_bash_decision "rm -rf $LEDGER_DIR")"
expect_guard deny "case 7d (rm the ledger file)" "$(guard_bash_decision "rm $LEDGER_KEY_FILE")"
expect_guard deny "case 7e (mv the ledger directory away)" "$(guard_bash_decision "mv $LEDGER_DIR $WORK/moved-ledger")"
expect_guard deny "case 7f (redirect onto the ledger file)" "$(guard_bash_decision "printf '{}' > $LEDGER_KEY_FILE")"
expect_guard deny "case 7g (find -delete in the ledger directory)" "$(guard_bash_decision "find $LEDGER_DIR -delete")"
expect_guard deny "case 7h (cp onto the ledger file, moved from review-fixes E2)" "$(guard_bash_decision "cp $REC_DIR/x.json $LEDGER_KEY_FILE")"
expect_guard deny "case 7i (rm -rf the ledger directory through ~)" "$(guard_bash_decision 'rm -rf ~/.claude/security-review-ledger')"
expect_guard deny "case 7j (redirect onto the ledger file through ~)" "$(guard_bash_decision "printf '{}' > ~/.claude/security-review-ledger/$LEDGER_KEY_NAME")"
expect_guard allow "case 7k (running the record script through Bash)" "$(guard_bash_decision "bash $CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh docs/x.json")"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate-shared-ledger.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate-shared-ledger.test.sh"
