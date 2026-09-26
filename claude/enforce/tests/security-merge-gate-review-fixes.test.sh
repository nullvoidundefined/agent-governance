#!/usr/bin/env bash
# Covers: hook:git-workflow-guard, hook:protected-path-guard
# Verifies the fixes the R-517 delta review of PR #145 asked for in the
# security merge gate (IAN-381, B-10c, rule R-109).
#
# A (HIGH): on a security-touching PR, a `## Security review` section with no
# `artefact` line denies `gh pr merge` with a reason naming R-109 and the
# missing `artefact` line, even when the section is otherwise valid, for
# example a clean `Nothing found:` line and no findings table, or a lone `No
# security control in range:` line. The same section with an `artefact` line
# naming the artefact recorded at the PR head reaches the plain R-514 ask.
#
# B (MEDIUM): the first record for a head stands. With the ledger's move to
# $HOME/.claude/security-review-ledger/ (B-10e) this case moved to
# security-merge-gate-shared-ledger.test.sh case 6.
#
# C (LOW): `--match-head-commit=<full head sha>` pins the merge exactly as the
# space-separated form does, so a valid review reaches the R-514 ask, and the
# `=` form naming another commit denies with a reason that names
# `--match-head-commit` rather than saying the merge carries none.
#
# D (LOW): when the detector outlives CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS,
# the merge still denies with R-109, and nothing the hook created is left
# under the TMPDIR it ran with, nor is the temporary directory the detector
# ran Semgrep from, wherever mktemp placed it.
#
# E (LOW): protected-path-guard.sh allows running the record script itself
# through Bash. The Bash redirection and cp denies moved with the ledger to
# security-merge-gate-shared-ledger.test.sh cases 7f and 7h (B-10e).
#
# The security repository mirrors security-merge-gate-ledger.test.sh: `main`
# and `origin/main` hold a README-only base commit, and a `feature` branch holds
# two PR commits (the first adds app/middleware/cors_config.py and two
# empty-findings artefacts under docs/reviews/, the second rewrites the CORS
# file), with the checkout left on `main`. gh is stubbed through CLAUDE_GH_CMD,
# Semgrep through CLAUDE_SEMGREP_CMD, and HOME is a scratch directory.
#
# Origin scheme (B-10f): each repository's `origin` fetch URL is the GitHub
# spelling https://github.com/fixture/<name>.git, and its push URL is the bare
# repository beside it, so `git remote get-url origin` prints the GitHub URL
# and a push still lands in the bare repository. The gh stub for a repository
# answers with url https://github.com/fixture/<name>/pull/42.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
GUARD="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
RECORD_SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS

failures=0
report_failure() { echo "FAIL security-merge-gate-review-fixes.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate-review-fixes.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}

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

# A Semgrep stand-in that hangs for 30 seconds before handing over to the clean
# stub (as in security-merge-gate-hardening.test.sh case 1). It first appends
# the directory the detector ran it from to SEMGREP_DIR_LOG, so case D can
# check that the hook's temporary scan directory is gone afterwards.
SEMGREP_DIR_LOG="$WORK/semgrep-dirs.log"
SLOW_STUB="$WORK/slow-semgrep"
printf '#!/bin/sh\npwd -P >> "%s"\nsleep 30\nexec "%s" "$@"\n' "$SEMGREP_DIR_LOG" "$CLEAN_STUB" > "$SLOW_STUB"
chmod +x "$SLOW_STUB"

STUB_DIR="$WORK/gh-stubs"
mkdir -p "$STUB_DIR"
# write_pr_stub <name> <body> <head oid> <base oid> <repo name>: a gh
# stand-in answering for PR 42 of a same-repository `feature` branch into
# `main` of https://github.com/fixture/<repo name>, headed at <head oid>, whose
# baseRefOid is <base oid>.
write_pr_stub() {
  local stub_path="$STUB_DIR/$1" pr_json
  pr_json=$(jq -nc --arg body "$2" --arg head "$3" --arg base "$4" --arg url "https://github.com/fixture/$5/pull/42" '{
    body: $body, labels: [], commits: [], headRefName: "feature", headRefOid: $head,
    baseRefName: "main", baseRefOid: $base, isCrossRepository: false, url: $url}')
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

# build_repo <name> <first commit setup>: builds a PR repository whose
# `feature` branch holds two commits. The first runs <first commit setup> (a
# function writing files into REPO_DIR) and commits everything; the second
# rewrites app/middleware/cors_config.py when it exists, otherwise
# app/greeting.py. Sets REPO_DIR, REPO_BASE, REPO_FIRST, and REPO_HEAD.
build_repo() {
  REPO_DIR="$WORK/$1"
  local origin_dir="$WORK/$1-origin.git"
  mkdir -p "$REPO_DIR"
  git init -q "$REPO_DIR" && git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/main
  printf 'Fixture repository %s.\n' "$1" > "$REPO_DIR/README.md"
  git_in "$REPO_DIR" add README.md
  git_in "$REPO_DIR" commit -q -m "chore: base"
  REPO_BASE=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q -b feature
  "$2"
  git_in "$REPO_DIR" add -A
  git_in "$REPO_DIR" commit -q -m "feat: first PR commit"
  REPO_FIRST=$(git -C "$REPO_DIR" rev-parse HEAD)
  if [ -f "$REPO_DIR/app/middleware/cors_config.py" ]; then
    printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
  else
    printf '%s\n' 'GREETING = "hello there"' > "$REPO_DIR/app/greeting.py"
  fi
  git_in "$REPO_DIR" add -A
  git_in "$REPO_DIR" commit -q -m "fix: second PR commit"
  REPO_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q main
  git init -q --bare "$origin_dir"
  git_in "$REPO_DIR" remote add origin "$origin_dir"
  git_in "$REPO_DIR" push -q origin main feature
  git_in "$REPO_DIR" fetch -q origin
  [ "$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null)" = "$REPO_BASE" ] ||
    { echo "FAIL security-merge-gate-review-fixes.test.sh: fixture setup could not point origin/main at the base in $1"; exit 1; }
  git_in "$REPO_DIR" remote set-url origin "https://github.com/fixture/$1.git"
  git_in "$REPO_DIR" remote set-url --push origin "$origin_dir"
  [ "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" = "https://github.com/fixture/$1.git" ] ||
    { echo "FAIL security-merge-gate-review-fixes.test.sh: fixture setup could not point origin at https://github.com/fixture/$1.git"; exit 1; }
  [ "$REPO_FIRST" != "$REPO_HEAD" ] ||
    { echo "FAIL security-merge-gate-review-fixes.test.sh: fixture setup did not create the second PR commit in $1"; exit 1; }
}

# write_security_files: the first commit of the security repository, a CORS
# config and two empty-findings artefacts.
write_security_files() {
  mkdir -p "$REPO_DIR/app/middleware" "$REPO_DIR/docs/reviews"
  printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
  printf '%s\n' "$ARTEFACT_CONTENT" > "$REPO_DIR/$ARTEFACT_PATH"
  printf '%s\n' "$ARTEFACT_CONTENT" > "$REPO_DIR/$OTHER_ARTEFACT_PATH"
}

# write_plain_code_file: the first commit of the plain-code repository, a code
# file with no security path or content, so only the Semgrep scan can decide.
write_plain_code_file() {
  mkdir -p "$REPO_DIR/app"
  printf '%s\n' 'GREETING = "hello"' > "$REPO_DIR/app/greeting.py"
}

# run_record <repo> <head> <path>: runs the record script for <path> from a
# detached checkout of <head>, checks `main` back out, and prints the script's
# exit status.
run_record() {
  local record_status
  git_in "$1" checkout -q --detach "$2"
  (cd "$1" && bash "$RECORD_SCRIPT" "$3" >/dev/null 2>&1)
  record_status=$?
  git_in "$1" checkout -q main
  printf '%s' "$record_status"
}

# codex_section <base> <head>: a valid R-517 `## Codex review` section.
codex_section() {
  printf '## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-10c.\n' "$1" "$2"
}

# security_header <base> <head>: the reviewer, model, and range lines of a
# current Security review on the strongest model, with no artefact line.
security_header() {
  printf '## Security review\n\n- reviewer: security-reviewer subagent\n- model: %s\n- range: %.7s..%.7s\n' "$EXPECTED_MODEL" "$1" "$2"
}

# pr_body <base> <head> <security section>: a PR body holding a summary, the
# Codex review, the given Security review section, and a testing section.
pr_body() {
  printf '## Summary\nWork.\n\n%s\n\n%s\n\n## Testing\nGreen.\n' "$(codex_section "$1" "$2")" "$3"
}

# run_merge <stub> <repo> <merge command> [<semgrep command>]: the hook's JSON
# output for <merge command> run from <repo>.
run_merge() {
  jq -nc --arg c "$3" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
    CLAUDE_GH_CMD="$1" CLAUDE_SEMGREP_CMD="${4:-$CLEAN_STUB}" "$HOOK" 2>/dev/null
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

# Build the security repository and record the artefact at its head.
build_repo sec write_security_files
SEC_DIR="$REPO_DIR" SEC_BASE="$REPO_BASE" SEC_FIRST="$REPO_FIRST" SEC_HEAD="$REPO_HEAD"
[ "$(run_record "$SEC_DIR" "$SEC_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
SEC_HEADER=$(security_header "$SEC_BASE" "$SEC_HEAD")
PINNED_MERGE="gh pr merge 42 --squash --match-head-commit $SEC_HEAD"
VALID_SECTION="$SEC_HEADER
- artefact: $ARTEFACT_PATH

$CLEAN_NOTHING_FOUND"

# --- A: a Security review with no artefact line --------------------------------
# Control: the same section with the recorded artefact's line reaches the ask,
# so the deny below comes from the missing line alone.
STUB=$(write_pr_stub casea-control "$(pr_body "$SEC_BASE" "$SEC_HEAD" "$VALID_SECTION")" "$SEC_HEAD" "$SEC_BASE" sec)
expect_r514_ask "case A control (artefact line naming the recorded artefact)" "$(run_merge "$STUB" "$SEC_DIR" "$PINNED_MERGE")"

# A1: reviewer, model, range, and a clean Nothing found line; no table and no
# artefact line.
STUB=$(write_pr_stub casea1 "$(pr_body "$SEC_BASE" "$SEC_HEAD" "$SEC_HEADER

$CLEAN_NOTHING_FOUND")" "$SEC_HEAD" "$SEC_BASE" sec)
expect_r109_deny "case A1 (Nothing found line, no artefact line)" "$(run_merge "$STUB" "$SEC_DIR" "$PINNED_MERGE")" artefact

# A2: reviewer, model, range, and a lone No security control in range line.
STUB=$(write_pr_stub casea2 "$(pr_body "$SEC_BASE" "$SEC_HEAD" "$SEC_HEADER

No security control in range: docs/notes.md")" "$SEC_HEAD" "$SEC_BASE" sec)
expect_r109_deny "case A2 (No security control in range line, no artefact line)" "$(run_merge "$STUB" "$SEC_DIR" "$PINNED_MERGE")" artefact

# --- B: moved to security-merge-gate-shared-ledger.test.sh case 6 (B-10e) ------

# --- C: the `=` form of --match-head-commit ------------------------------------
# A fresh repository with its own single record, so the outcome of case B
# cannot decide case C.
build_repo pin write_security_files
PIN_DIR="$REPO_DIR" PIN_BASE="$REPO_BASE" PIN_FIRST="$REPO_FIRST" PIN_HEAD="$REPO_HEAD"
[ "$(run_record "$PIN_DIR" "$PIN_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case C setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
PIN_SECTION="$(security_header "$PIN_BASE" "$PIN_HEAD")
- artefact: $ARTEFACT_PATH

$CLEAN_NOTHING_FOUND"
STUB=$(write_pr_stub casec "$(pr_body "$PIN_BASE" "$PIN_HEAD" "$PIN_SECTION")" "$PIN_HEAD" "$PIN_BASE" pin)
# C0 (control): the space-separated form reaches the ask, so C1 differs from it
# in the flag's form alone.
expect_r514_ask "case C0 control (--match-head-commit <full head sha>)" \
  "$(run_merge "$STUB" "$PIN_DIR" "gh pr merge 42 --squash --match-head-commit $PIN_HEAD")"
# C1: `--match-head-commit=<full head>` pins the reviewed head.
expect_r514_ask "case C1 (--match-head-commit=<full head sha>)" \
  "$(run_merge "$STUB" "$PIN_DIR" "gh pr merge 42 --squash --match-head-commit=$PIN_HEAD")"
# C2: `--match-head-commit=<another sha>` denies, naming the flag as present.
OUTPUT=$(run_merge "$STUB" "$PIN_DIR" "gh pr merge 42 --squash --match-head-commit=$PIN_FIRST")
if expect_r109_deny "case C2 (--match-head-commit=<another commit>)" "$OUTPUT" --match-head-commit; then
  C2_REASON=$(read_reason "$OUTPUT")
  case "$C2_REASON" in
    *"carries no"* | *"without --match-head-commit"* | *"without \`--match-head-commit"* | *"no \`--match-head-commit"* | *"no --match-head-commit"*)
      report_failure "case C2: deny reason says the merge carries no --match-head-commit, though it carries one naming another commit: $C2_REASON" ;;
  esac
fi

# --- D: an expired detector leaves nothing under TMPDIR ------------------------
# The PR changes a code file with no security path or content, so only the
# Semgrep scan can answer, and Semgrep hangs past the 2 second deadline.
build_repo plain write_plain_code_file
PLAIN_DIR="$REPO_DIR" PLAIN_BASE="$REPO_BASE" PLAIN_HEAD="$REPO_HEAD"
HOOK_TMPDIR=$(cd "$(mktemp -d "$WORK/hook-tmp.XXXXXX")" && pwd -P)
STUB=$(write_pr_stub cased "$(pr_body "$PLAIN_BASE" "$PLAIN_HEAD" "")" "$PLAIN_HEAD" "$PLAIN_BASE" plain)
EXPIRY_START=$(date +%s)
EXPIRY_OUTPUT=$(jq -nc --arg c "gh pr merge 42 --squash --match-head-commit $PLAIN_HEAD" --arg d "$PLAIN_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
  TMPDIR="$HOOK_TMPDIR" CLAUDE_GH_CMD="$STUB" CLAUDE_SEMGREP_CMD="$SLOW_STUB" CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS=2 "$HOOK" 2>/dev/null)
EXPIRY_ELAPSED=$(($(date +%s) - EXPIRY_START))
expect_r109_deny "case D (detector past its deadline)" "$EXPIRY_OUTPUT"
[ "$EXPIRY_ELAPSED" -ge 2 ] ||
  report_failure "case D setup: the hook answered in ${EXPIRY_ELAPSED}s, so the detector deadline never expired"
[ "$EXPIRY_ELAPSED" -lt 10 ] ||
  report_failure "case D: the hook took ${EXPIRY_ELAPSED}s, past the 2 second detector deadline"
# The directory the detector ran Semgrep from is the hook's own temporary scan
# directory unless it lies inside the PR repository.
SEMGREP_RUN_DIR=$(head -1 "$SEMGREP_DIR_LOG" 2>/dev/null)
[ -n "$SEMGREP_RUN_DIR" ] ||
  report_failure "case D setup: the hanging Semgrep stub never ran, so the detector deadline was not what expired"
case "$SEMGREP_RUN_DIR" in "$PLAIN_DIR" | "$PLAIN_DIR"/*) SEMGREP_RUN_DIR="" ;; esac
# Allow up to about 2 seconds for cleanup to finish.
leftover_entries=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  leftover_entries=$(find "$HOOK_TMPDIR" -mindepth 1 2>/dev/null)
  [ -n "$SEMGREP_RUN_DIR" ] && [ -e "$SEMGREP_RUN_DIR" ] && leftover_entries="$leftover_entries $SEMGREP_RUN_DIR"
  [ -z "$leftover_entries" ] && break
  sleep 0.2
done
[ -z "$leftover_entries" ] ||
  report_failure "case D: the expired detector left its temporary files behind (under the hook's TMPDIR or the directory Semgrep ran from): $(printf '%s' "$leftover_entries" | tr '\n' ' ')"

# --- E: running the record script through Bash is allowed ---------------------
# The redirection (E1) and cp (E2) denies onto the ledger moved to
# security-merge-gate-shared-ledger.test.sh cases 7f and 7h (B-10e).
# guard_bash_decision <command>: protected-path-guard's decision for a Bash
# call running <command> from the security repository, "allow" when silent.
guard_bash_decision() {
  local guard_output
  guard_output=$(jq -nc --arg c "$1" --arg d "$SEC_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$GUARD" 2>/dev/null)
  if [ -z "$guard_output" ]; then echo allow; else printf '%s' "$guard_output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi
}
E3_DECISION=$(guard_bash_decision "bash $CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh docs/x.json")
[ "$E3_DECISION" != deny ] || report_failure "case E3: running security-review-record.sh through Bash was denied"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate-review-fixes.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate-review-fixes.test.sh"
