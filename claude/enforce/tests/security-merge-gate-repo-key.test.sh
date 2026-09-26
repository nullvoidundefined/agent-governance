#!/usr/bin/env bash
# Covers: hook:git-workflow-guard, hook:protected-path-guard
# Verifies that the Security review ledger (IAN-381, B-10f, rule R-109) is
# keyed by the normalized repository identity rather than by the raw origin
# URL, that the merge gate judges a merge by the repository the PR's own
# GitHub url names, and that the guard reads `$HOME` in a Bash target.
#
# The key: the ledger file is $HOME/.claude/security-review-ledger/<key>.json,
# where <key> is the sha256 hex digest (`printf '%s' "$identity" | shasum -a
# 256`, no trailing newline) of the identity `host/owner/repo`, lowercased,
# with any scheme, `user@`, `.git` suffix, and trailing slash removed. The
# record script reads the identity from the repository's origin URL, written
# either as `scheme://[user@]host[:port]/owner/repo[.git]` or scp-like as
# `[user@]host:owner/repo[.git]`. hooks/security-review-ledger-path.sh computes
# it; this fixture calls its print_security_review_ledger_path <directory
# inside a repository> and compares the result with the key spelled here.
# https://github.com/o/r, https://github.com/o/r.git, git@github.com:o/r.git,
# ssh://git@github.com/o/r, and https://GitHub.com/O/R/ all key one file.
#
# The gate: on a security-touching PR, hooks/git-workflow-guard.sh computes
# the key from the PR's GitHub `url` (https://github.com/<owner>/<repo>/pull/<n>)
# and denies `gh pr merge` with a reason naming R-109 and `origin` when the
# merge checkout's normalized origin identity differs from the url's, or when
# the origin cannot be normalized (a file path). A record made from a clone
# whose origin is https://... merges from a checkout whose origin is the
# git@...:....git spelling of the same repository, reaching the R-514 ask, and
# re-pointing origin at another spelling of the same repository does not let a
# second record for the same head in: the first record stands.
#
# The guard: hooks/protected-path-guard.sh denies a Bash rm -rf, mv, or
# redirection aimed at the ledger directory or a file in it when the target is
# written through `$HOME` or `${HOME}`, quoted or not, and allows `echo
# "$HOME"` and `ls "$HOME/.claude"`.
#
# Origin scheme: each repository is built with `main` and `origin/main` holding
# a README-only base commit and a `feature` branch holding two PR commits (the
# first adds app/middleware/cors_config.py and two artefacts with identical
# content under docs/reviews/, the second rewrites the CORS file), pushed to a
# bare repository beside it. Its `origin` fetch URL is then set to a GitHub
# spelling, and its push URL stays the bare repository, so `git remote get-url
# origin` prints the GitHub spelling (checked at setup) and nothing reaches the
# network. A clone is made from the bare repository and re-pointed the same
# way. The gh stub answers with url https://github.com/fixture/<repo>/pull/42.
# gh is stubbed through CLAUDE_GH_CMD and Semgrep through CLAUDE_SEMGREP_CMD,
# and HOME is a scratch directory throughout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
GUARD="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
RECORD_SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh"
LEDGER_PATH_HELPER="$CLAUDE_HARNESS_ROOT/hooks/security-review-ledger-path.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS

failures=0
report_failure() { echo "FAIL security-merge-gate-repo-key.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
SCRATCH_HOME="$WORK/home"
export HOME="$SCRATCH_HOME"
mkdir -p "$SCRATCH_HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0

EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate-repo-key.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}

LEDGER_DIR="$SCRATCH_HOME/.claude/security-review-ledger"
ARTEFACT_PATH=docs/reviews/security-review-pr42.json
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

# expected_ledger_path <identity>: the ledger file the spec assigns to the
# normalized identity host/owner/repo, spelled here independently of the hook.
expected_ledger_path() {
  printf '%s/%s.json' "$LEDGER_DIR" "$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')"
}

# helper_ledger_path <repo>: what print_security_review_ledger_path in
# hooks/security-review-ledger-path.sh prints for <repo>; empty on failure.
helper_ledger_path() {
  (. "$LEDGER_PATH_HELPER" && print_security_review_ledger_path "$1") 2>/dev/null || true
}

# point_origin <repo> <fetch url> <push url>: sets origin's fetch URL to the
# given spelling and its push URL to the bare repository, then checks that
# `git remote get-url origin` prints the spelling.
point_origin() {
  git_in "$1" remote set-url origin "$2"
  git_in "$1" remote set-url --push origin "$3"
  [ "$(git -C "$1" remote get-url origin 2>/dev/null)" = "$2" ] ||
    { echo "FAIL security-merge-gate-repo-key.test.sh: fixture setup could not point origin of $1 at $2"; exit 1; }
}

# build_pr_repo <name> <origin fetch url>: builds the security-touching PR
# repository described in the header with origin fetching from <origin fetch
# url>. Sets REPO_DIR, REPO_ORIGIN (the bare repository), REPO_BASE (also the
# local origin/main), and REPO_HEAD.
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
  printf '%s\n' 'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]' > "$REPO_DIR/app/middleware/cors_config.py"
  git_in "$REPO_DIR" add app
  git_in "$REPO_DIR" commit -q -m "fix: second PR commit"
  REPO_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q main
  git init -q --bare "$REPO_ORIGIN"
  git -C "$REPO_ORIGIN" symbolic-ref HEAD refs/heads/main
  git_in "$REPO_DIR" remote add origin "$REPO_ORIGIN"
  git_in "$REPO_DIR" push -q origin main feature
  git_in "$REPO_DIR" fetch -q origin
  [ "$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null)" = "$REPO_BASE" ] ||
    { echo "FAIL security-merge-gate-repo-key.test.sh: fixture setup could not point origin/main at the base in $1"; exit 1; }
  point_origin "$REPO_DIR" "$2" "$REPO_ORIGIN"
}

# run_record <checkout> <head> <path>: runs the record script for <path> from
# <checkout> with <head> detached, restores the branch it had, and prints the
# script's exit status.
run_record() {
  local record_status previous_ref
  previous_ref=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$1" rev-parse HEAD)
  git_in "$1" checkout -q --detach "$2"
  (cd "$1" && bash "$RECORD_SCRIPT" "$3" >/dev/null 2>&1)
  record_status=$?
  git_in "$1" checkout -q "$previous_ref"
  printf '%s' "$record_status"
}

# pr_body <base> <head> <artefact path>: a PR body holding a summary, a valid
# Codex review, a Security review that clears every check older than B-10f
# (reviewer, model, current range, an artefact line, a clean Nothing found
# line), and a testing section.
pr_body() {
  printf '## Summary\nWork.\n\n## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-10f.\n\n## Security review\n\n- reviewer: security-reviewer subagent\n- model: %s\n- range: %.7s..%.7s\n- artefact: %s\n\n%s\n\n## Testing\nGreen.\n' \
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

# expect_r109_deny <case> <output> <phrase>: the merge is denied, and the
# reason names R-109 and contains <phrase>.
expect_r109_deny() {
  local decision reason
  decision=$(read_decision "$2")
  reason=$(read_reason "$2")
  [ "$decision" = deny ] || { report_failure "$1: expected deny, got $decision ($reason)"; return 1; }
  case "$reason" in *R-109*) ;; *) report_failure "$1: deny reason does not name R-109: $reason"; return 1 ;; esac
  case "$reason" in *"$3"*) ;; *) report_failure "$1: deny reason does not contain '$3': $reason"; return 1 ;; esac
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

# snapshot_ledger_dir: one line per file in the ledger directory, its name and
# the sha256 of its content, so any new or changed ledger file shows.
snapshot_ledger_dir() {
  local ledger_file
  for ledger_file in "$LEDGER_DIR"/*; do
    [ -f "$ledger_file" ] || continue
    printf '%s %s\n' "${ledger_file##*/}" "$(shasum -a 256 < "$ledger_file" | awk '{print $1}')"
  done
}

# --- Case 1: every spelling of one repository keys one ledger file -------------
KEY_DIR="$WORK/key-probe"
git init -q "$KEY_DIR"
git_in "$KEY_DIR" remote add origin https://github.com/o/r
EXPECTED_O_R_LEDGER=$(expected_ledger_path github.com/o/r)
spelling_index=0
for origin_spelling in https://github.com/o/r https://github.com/o/r.git git@github.com:o/r.git ssh://git@github.com/o/r https://GitHub.com/O/R/; do
  spelling_index=$((spelling_index + 1))
  git_in "$KEY_DIR" remote set-url origin "$origin_spelling"
  [ "$(git -C "$KEY_DIR" remote get-url origin 2>/dev/null)" = "$origin_spelling" ] ||
    { echo "FAIL security-merge-gate-repo-key.test.sh: fixture setup could not set origin to $origin_spelling"; exit 1; }
  HELPER_PATH=$(helper_ledger_path "$KEY_DIR")
  [ "$HELPER_PATH" = "$EXPECTED_O_R_LEDGER" ] ||
    report_failure "case 1.$spelling_index (origin $origin_spelling): print_security_review_ledger_path printed '$HELPER_PATH', not <scratch home>/.claude/security-review-ledger/<sha256 of github.com/o/r>.json ($EXPECTED_O_R_LEDGER)"
done
# Control: another repository keys another file, so the key is not constant.
git_in "$KEY_DIR" remote set-url origin https://github.com/o/other.git
OTHER_REPO_PATH=$(helper_ledger_path "$KEY_DIR")
[ -n "$OTHER_REPO_PATH" ] && [ "$OTHER_REPO_PATH" != "$EXPECTED_O_R_LEDGER" ] ||
  report_failure "case 1 control (origin https://github.com/o/other.git): print_security_review_ledger_path printed '$OTHER_REPO_PATH', which is empty or the o/r ledger"

# --- Case 2: a re-pointed origin denies ----------------------------------------
# The PR belongs to fixture/victim; the merge checkout's origin is re-pointed at
# fixture/decoy and a record is made there, so the only thing wrong is that the
# checkout's origin is not the PR's repository.
build_pr_repo victim https://github.com/fixture/decoy.git
VICTIM_DIR="$REPO_DIR" VICTIM_ORIGIN="$REPO_ORIGIN" VICTIM_BASE="$REPO_BASE" VICTIM_HEAD="$REPO_HEAD"
[ "$(run_record "$VICTIM_DIR" "$VICTIM_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case 2 setup: security-review-record.sh could not record $ARTEFACT_PATH with origin fixture/decoy"
STUB=$(write_pr_stub case2 "$(pr_body "$VICTIM_BASE" "$VICTIM_HEAD" "$ARTEFACT_PATH")" "$VICTIM_HEAD" "$VICTIM_BASE" victim)
expect_r109_deny "case 2 (merge checkout's origin is fixture/decoy, PR url is fixture/victim)" "$(run_merge "$STUB" "$VICTIM_DIR" "$VICTIM_HEAD")" origin

# Control: pointed back at fixture/victim and recorded there, the same PR
# reaches the ask, so the deny above comes from the origin alone.
point_origin "$VICTIM_DIR" https://github.com/fixture/victim.git "$VICTIM_ORIGIN"
[ "$(run_record "$VICTIM_DIR" "$VICTIM_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case 2 control setup: security-review-record.sh could not record $ARTEFACT_PATH with origin fixture/victim"
expect_r514_ask "case 2 control (origin and PR url both fixture/victim)" "$(run_merge "$STUB" "$VICTIM_DIR" "$VICTIM_HEAD")"

# --- Case 3: an origin that cannot be normalized denies -------------------------
# The origin is the bare repository's file path, a record is made against it,
# and the PR url names fixture/pathorigin.
build_pr_repo pathorigin https://github.com/fixture/pathorigin.git
PATH_DIR="$REPO_DIR" PATH_ORIGIN="$REPO_ORIGIN" PATH_BASE="$REPO_BASE" PATH_HEAD="$REPO_HEAD"
point_origin "$PATH_DIR" "$PATH_ORIGIN" "$PATH_ORIGIN"
run_record "$PATH_DIR" "$PATH_HEAD" "$ARTEFACT_PATH" >/dev/null
STUB=$(write_pr_stub case3 "$(pr_body "$PATH_BASE" "$PATH_HEAD" "$ARTEFACT_PATH")" "$PATH_HEAD" "$PATH_BASE" pathorigin)
expect_r109_deny "case 3 (merge checkout's origin is a file path)" "$(run_merge "$STUB" "$PATH_DIR" "$PATH_HEAD")" origin

# --- Case 4: an honest record merges across spellings --------------------------
# Recorded from a checkout whose origin is https://github.com/fixture/honest,
# merged from a clone whose origin is git@github.com:fixture/honest.git.
build_pr_repo honest https://github.com/fixture/honest
HONEST_DIR="$REPO_DIR" HONEST_ORIGIN="$REPO_ORIGIN" HONEST_BASE="$REPO_BASE" HONEST_HEAD="$REPO_HEAD"
HONEST_LEDGER=$(expected_ledger_path github.com/fixture/honest)
[ "$(run_record "$HONEST_DIR" "$HONEST_HEAD" "$ARTEFACT_PATH")" = 0 ] ||
  report_failure "case 4 setup: security-review-record.sh could not record $ARTEFACT_PATH with origin https://github.com/fixture/honest"
[ -f "$HONEST_LEDGER" ] ||
  report_failure "case 4: the record made with origin https://github.com/fixture/honest is not in <sha256 of github.com/fixture/honest>.json ($HONEST_LEDGER)"
HONEST_CLONE="$WORK/honest-ssh-clone"
git clone -q -b main "$HONEST_ORIGIN" "$HONEST_CLONE" >/dev/null 2>&1
point_origin "$HONEST_CLONE" git@github.com:fixture/honest.git "$HONEST_ORIGIN"
[ "$(git -C "$HONEST_CLONE" rev-parse refs/remotes/origin/main 2>/dev/null)" = "$HONEST_BASE" ] &&
  git -C "$HONEST_CLONE" cat-file -e "$HONEST_HEAD^{commit}" 2>/dev/null ||
  { echo "FAIL security-merge-gate-repo-key.test.sh: fixture setup could not clone origin/main and the PR head into $HONEST_CLONE"; exit 1; }
STUB=$(write_pr_stub case4 "$(pr_body "$HONEST_BASE" "$HONEST_HEAD" "$ARTEFACT_PATH")" "$HONEST_HEAD" "$HONEST_BASE" honest)
expect_r514_ask "case 4 (recorded with the https spelling, merged from the git@ spelling)" "$(run_merge "$STUB" "$HONEST_CLONE" "$HONEST_HEAD")"

# --- Case 5: another spelling does not let a second record in -----------------
# The recording checkout's origin is re-pointed at the git@ spelling of the
# same repository and records another artefact for the same head.
point_origin "$HONEST_DIR" git@github.com:fixture/honest.git "$HONEST_ORIGIN"
LEDGER_BEFORE=$(snapshot_ledger_dir)
SECOND_STATUS=$(run_record "$HONEST_DIR" "$HONEST_HEAD" "$OTHER_ARTEFACT_PATH")
[ "$SECOND_STATUS" != 0 ] ||
  report_failure "case 5a: security-review-record.sh exited 0 recording another artefact for head $(printf '%.7s' "$HONEST_HEAD") after origin was re-pointed at git@github.com:fixture/honest.git"
[ "$(snapshot_ledger_dir)" = "$LEDGER_BEFORE" ] ||
  report_failure "case 5a: the ledger directory changed when a second record for the same head was made under another spelling: $(snapshot_ledger_dir | tr '\n' ' ')"
# The first record still decides, from the re-pointed checkout.
expect_r514_ask "case 5b (first record still decides after the re-pointed second record)" "$(run_merge "$STUB" "$HONEST_DIR" "$HONEST_HEAD")"

# --- Case 6: the guard reads $HOME in a Bash target ----------------------------
mkdir -p "$LEDGER_DIR"
HONEST_KEY_NAME="${HONEST_LEDGER##*/}"

# guard_bash_decision <command>: the guard's decision for a Bash call running
# <command> from the honest checkout, "allow" when silent.
guard_bash_decision() {
  local guard_output
  guard_output=$(jq -nc --arg c "$1" --arg d "$HONEST_DIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$GUARD" 2>/dev/null)
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

# The literal words `$HOME` and `${HOME}`, which reach the guard unexpanded the
# way a session writes them. $HOME here is data under test, not the location
# of the hook under test, which comes from CLAUDE_HARNESS_ROOT.
# shellcheck disable=SC2016
HOME_WORD='$HOME'
# shellcheck disable=SC2016
HOME_BRACED_WORD='${HOME}'
LEDGER_DIR_VIA_HOME="$HOME_WORD/.claude/security-review-ledger"
CMD_6A="rm -rf \"$LEDGER_DIR_VIA_HOME\""
CMD_6B="rm -rf $HOME_BRACED_WORD/.claude/security-review-ledger"
CMD_6C="mv \"$LEDGER_DIR_VIA_HOME\" /tmp/x"
CMD_6D="printf '{}' > \"$LEDGER_DIR_VIA_HOME/$HONEST_KEY_NAME\""
CMD_6_ECHO="echo \"$HOME_WORD\""
CMD_6_LS="ls \"$HOME_WORD/.claude\""
expect_guard deny "case 6a ($CMD_6A)" "$(guard_bash_decision "$CMD_6A")"
expect_guard deny "case 6b ($CMD_6B, unquoted)" "$(guard_bash_decision "$CMD_6B")"
expect_guard deny "case 6c ($CMD_6C)" "$(guard_bash_decision "$CMD_6C")"
expect_guard deny "case 6d ($CMD_6D)" "$(guard_bash_decision "$CMD_6D")"
expect_guard allow "case 6 control ($CMD_6_ECHO)" "$(guard_bash_decision "$CMD_6_ECHO")"
expect_guard allow "case 6 control ($CMD_6_LS)" "$(guard_bash_decision "$CMD_6_LS")"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate-repo-key.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate-repo-key.test.sh"
