#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Verifies the security merge gate in git-workflow-guard.sh (IAN-381, B-9 core
# and B-14, rule R-109). On a PR whose range touches security code, as decided
# by the sourced detector hooks/security-surface.sh (is_security_surface
# <repo-top> <base-oid> <head-oid>), `gh pr merge` is denied with a reason
# naming R-109 unless the PR body carries a `## Security review` section whose
# `reviewer` line is non-empty, whose `model` line equals `securityReviewModel`
# in enforce/security-review-model.json, and whose `range` line's head endpoint
# identifies the PR head commit by the same prefix rule the Codex review uses,
# and whose `artefact` line names the reviewer's saved output as recorded in the
# review ledger by enforce/security-review-record.sh.
# A PR that touches no security code reaches the R-514 ask exactly as before,
# and a detector that cannot run (it fails, or the PR head is not in the local
# repository) denies with R-109 rather than letting the merge through.
#
# Each case builds a throwaway repository: `main` and `origin/main` hold the
# base commit, a `feature` branch holds the PR's commits (two, plus a third
# adding the empty-findings artefact in the security repository), and the checkout
# stays on `main`, so the gate must judge the range base..headRefOid rather
# than whatever happens to be checked out. gh is stubbed through CLAUDE_GH_CMD
# and Semgrep through CLAUDE_SEMGREP_CMD, so neither GitHub nor Semgrep is a
# variable, and HOME is a scratch directory throughout.
#
# Origin scheme (B-10f): each repository's `origin` fetch URL is the GitHub
# spelling https://github.com/fixture/<name>.git, and its push URL is the bare
# repository beside it, so `git remote get-url origin` prints the GitHub URL
# and a push still lands in the bare repository. The gh stub for a repository
# answers with url https://github.com/fixture/<name>/pull/42, so the PR url and
# the merge checkout's origin name the same repository.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST

failures=0
report_failure() { echo "FAIL security-merge-gate.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

# The one key the model is read from (invariant: no hardcoded model name).
EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}
WRONG_MODEL=sonnet
[ "$EXPECTED_MODEL" = "$WRONG_MODEL" ] && WRONG_MODEL=haiku

# A Semgrep stand-in reporting a complete clean scan: every target it was given
# is listed under paths.scanned (copied from security-surface.test.sh).
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

# A Semgrep stand-in that crashes, so the detector itself fails (returns 2).
CRASH_STUB="$WORK/crash-semgrep"
printf '#!/bin/sh\necho "semgrep: internal error" >&2\nexit 2\n' > "$CRASH_STUB"
chmod +x "$CRASH_STUB"

STUB_DIR="$WORK/gh-stubs"
mkdir -p "$STUB_DIR"
# write_gh_stub <name> <json> [<status>]: an executable gh stand-in that prints
# <json> as the `gh pr view` answer and exits with <status> (default 0).
# Copied from git-workflow-guard.test.sh.
write_gh_stub() {
  local stub_path="$STUB_DIR/$1"
  printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\nexit %s\n' "$2" "${3:-0}" >"$stub_path"
  chmod +x "$stub_path"
  printf '%s' "$stub_path"
}

# write_pr_stub <name> <body> <head oid> <base oid> <repo name>: a gh
# stand-in answering for PR 42 of a same-repository `feature` branch into
# `main` of https://github.com/fixture/<repo name>, headed at <head oid>, whose
# baseRefOid is <base oid> (the local origin/main, so the base the gate reads
# is current).
write_pr_stub() {
  local pr_json
  pr_json=$(jq -nc --arg body "$2" --arg head "$3" --arg base "$4" --arg url "https://github.com/fixture/$5/pull/42" '{
    body: $body, labels: [], commits: [], headRefName: "feature", headRefOid: $head,
    baseRefName: "main", baseRefOid: $base, isCrossRepository: false, url: $url}')
  write_gh_stub "$1" "$pr_json"
}

# git_in <repo> <git args>...: git with a fixed identity and no signing.
git_in() {
  local repo="$1"
  shift
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1
}

# build_pr_repo <name> <path> <first content> <second content>: builds a
# repository whose `main` (and `origin/main`) holds a README-only base commit
# and whose `feature` branch adds <path> in one commit and rewrites it in a
# second, then checks `main` back out. Sets REPO_DIR, REPO_BASE, REPO_FIRST
# (the older PR commit), and REPO_HEAD (the PR head).
build_pr_repo() {
  local name="$1" file_path="$2" first_content="$3" second_content="$4"
  REPO_DIR="$WORK/$name"
  local origin_dir="$WORK/$name-origin.git"
  mkdir -p "$REPO_DIR"
  git init -q "$REPO_DIR" && git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/main
  printf 'Fixture repository.\n' > "$REPO_DIR/README.md"
  git_in "$REPO_DIR" add README.md
  git_in "$REPO_DIR" commit -q -m "chore: base"
  REPO_BASE=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q -b feature
  mkdir -p "$(dirname "$REPO_DIR/$file_path")"
  printf '%s\n' "$first_content" > "$REPO_DIR/$file_path"
  git_in "$REPO_DIR" add "$file_path"
  git_in "$REPO_DIR" commit -q -m "feat: first PR commit"
  REPO_FIRST=$(git -C "$REPO_DIR" rev-parse HEAD)
  printf '%s\n' "$second_content" > "$REPO_DIR/$file_path"
  git_in "$REPO_DIR" add "$file_path"
  git_in "$REPO_DIR" commit -q -m "fix: second PR commit"
  REPO_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  git_in "$REPO_DIR" checkout -q main
  git init -q --bare "$origin_dir"
  git_in "$REPO_DIR" remote add origin "$origin_dir"
  git_in "$REPO_DIR" push -q origin main feature
  git_in "$REPO_DIR" fetch -q origin
  [ "$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null)" = "$REPO_BASE" ] ||
    { echo "FAIL security-merge-gate.test.sh: fixture setup could not point origin/main at the base in $name"; exit 1; }
  git_in "$REPO_DIR" remote set-url origin "https://github.com/fixture/$name.git"
  git_in "$REPO_DIR" remote set-url --push origin "$origin_dir"
  [ "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" = "https://github.com/fixture/$name.git" ] ||
    { echo "FAIL security-merge-gate.test.sh: fixture setup could not point origin at https://github.com/fixture/$name.git"; exit 1; }
}

# codex_section <base> <head>: a valid R-517 `## Codex review` section.
codex_section() {
  printf '## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-9 and B-14.\n' "$1" "$2"
}

# The empty-findings artefact the security PR commits at its head, recorded in
# the review ledger with enforce/security-review-record.sh (B-10b, B-10c).
ARTEFACT_PATH=docs/reviews/security-review-empty.json
RECORD_SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/security-review-record.sh"

# security_section <reviewer> <model> <base> <head>: a `## Security review`
# section with the given fields, an `artefact` line naming the committed
# empty-findings artefact, and a clean control written in the prompt's
# `Nothing found:` form, so the section records what was tried.
security_section() {
  printf '## Security review\n- reviewer: %s\n- model: %s\n- range: %.7s..%.7s\n- artefact: %s\n\nNothing found: CORS: sources env CORS_ORIGIN: tried *, null, https://evil.example\n' "$1" "$2" "$3" "$4" "$ARTEFACT_PATH"
}

# pr_body <section>...: a PR body holding a summary, the given sections, and a
# testing section.
pr_body() {
  local section
  printf '## Summary\nWork.\n\n'
  for section in "$@"; do printf '%s\n' "$section"; done
  printf '## Testing\nGreen.\n'
}

# run_guard <gh stub> <repo> <semgrep command> [<merge command>]: the hook's
# JSON output for <merge command> (default `gh pr merge 42 --squash`) run from
# <repo>.
run_guard() {
  jq -nc --arg c "${4:-gh pr merge 42 --squash}" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
    CLAUDE_GH_CMD="$1" CLAUDE_SEMGREP_CMD="$3" "$HOOK" 2>/dev/null
}

# read_decision <output> / read_reason <output>: the decision ("none" when the
# hook printed nothing) and its reason.
read_decision() {
  if [ -z "$1" ]; then echo none; else printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo unreadable; fi
}
read_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

# expect_r109_deny <case> <output>: the merge is denied and the reason names R-109.
expect_r109_deny() {
  local decision reason
  decision=$(read_decision "$2")
  reason=$(read_reason "$2")
  [ "$decision" = deny ] || { report_failure "$1: expected deny, got $decision ($reason)"; return 1; }
  case "$reason" in *R-109*) ;; *) report_failure "$1: deny reason does not name R-109: $reason"; return 1 ;; esac
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

# Security-touching PR: app/middleware/cors_config.py is a path hit.
build_pr_repo sec app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
  'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]'
SEC_DIR="$REPO_DIR" SEC_BASE="$REPO_BASE" SEC_FIRST="$REPO_FIRST"
# A third PR commit adds the empty-findings artefact, so it exists at the PR
# head, and the record script writes it into the ledger from a checkout of
# that head, the way a reviewer records it after committing.
git_in "$SEC_DIR" checkout -q feature
mkdir -p "$SEC_DIR/docs/reviews"
printf '%s\n' '{"findings":[]}' > "$SEC_DIR/$ARTEFACT_PATH"
git_in "$SEC_DIR" add docs
git_in "$SEC_DIR" commit -q -m "docs: security review artefact"
SEC_HEAD=$(git -C "$SEC_DIR" rev-parse HEAD)
git_in "$SEC_DIR" push -q origin feature
(cd "$SEC_DIR" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1) ||
  report_failure "setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
git_in "$SEC_DIR" checkout -q main
[ "$SEC_HEAD" != "$REPO_HEAD" ] || report_failure "setup: the artefact commit was not created"
SEC_CODEX=$(codex_section "$SEC_BASE" "$SEC_HEAD")

# Case 1: valid Codex review, no Security review section.
STUB=$(write_pr_stub case1 "$(pr_body "$SEC_CODEX")" "$SEC_HEAD" "$SEC_BASE" sec)
expect_r109_deny "case 1 (no security review)" "$(run_guard "$STUB" "$SEC_DIR" "$CLEAN_STUB")"

# Case 2: Security review on the wrong model; the reason names the expected one.
STUB=$(write_pr_stub case2 "$(pr_body "$SEC_CODEX" "$(security_section security-reviewer "$WRONG_MODEL" "$SEC_BASE" "$SEC_HEAD")")" "$SEC_HEAD" "$SEC_BASE" sec)
OUTPUT=$(run_guard "$STUB" "$SEC_DIR" "$CLEAN_STUB")
if expect_r109_deny "case 2 (wrong model $WRONG_MODEL)" "$OUTPUT"; then
  case "$(read_reason "$OUTPUT")" in
    *"$EXPECTED_MODEL"*) ;;
    *) report_failure "case 2: deny reason does not name the expected model $EXPECTED_MODEL: $(read_reason "$OUTPUT")" ;;
  esac
fi

# Case 3: Security review whose range head is the older PR commit.
STUB=$(write_pr_stub case3 "$(pr_body "$SEC_CODEX" "$(security_section security-reviewer "$EXPECTED_MODEL" "$SEC_BASE" "$SEC_FIRST")")" "$SEC_HEAD" "$SEC_BASE" sec)
expect_r109_deny "case 3 (stale range head)" "$(run_guard "$STUB" "$SEC_DIR" "$CLEAN_STUB")"

# Case 4: valid reviewer, model, and range, and an artefact line naming the
# artefact recorded at the PR head: R-109 is satisfied and R-514 asks.
STUB=$(write_pr_stub case4 "$(pr_body "$SEC_CODEX" "$(security_section security-reviewer "$EXPECTED_MODEL" "$SEC_BASE" "$SEC_HEAD")")" "$SEC_HEAD" "$SEC_BASE" sec)
expect_r514_ask "case 4 (valid security review)" "$(run_guard "$STUB" "$SEC_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $SEC_HEAD")"

# Case 4b: an empty reviewer value does not count as a reviewer.
STUB=$(write_pr_stub case4b "$(pr_body "$SEC_CODEX" "$(printf '## Security review\n- reviewer:\n- model: %s\n- range: %.7s..%.7s\n- Findings: none open.\n' "$EXPECTED_MODEL" "$SEC_BASE" "$SEC_HEAD")")" "$SEC_HEAD" "$SEC_BASE" sec)
expect_r109_deny "case 4b (empty reviewer)" "$(run_guard "$STUB" "$SEC_DIR" "$CLEAN_STUB")"

# Case 5 (B-14): a docs-only PR with a valid Codex review and no Security
# review reaches the same R-514 ask as before the gate existed.
build_pr_repo docs docs/guide.md 'Read the guide.' 'Read the guide carefully.'
DOCS_DIR="$REPO_DIR" DOCS_BASE="$REPO_BASE" DOCS_HEAD="$REPO_HEAD"
STUB=$(write_pr_stub case5 "$(pr_body "$(codex_section "$DOCS_BASE" "$DOCS_HEAD")")" "$DOCS_HEAD" "$DOCS_BASE" docs)
expect_r514_ask "case 5 (no security surface)" "$(run_guard "$STUB" "$DOCS_DIR" "$CLEAN_STUB")"

# Case 6a (fail closed): a code change with no security path or content, whose
# Semgrep scan crashes, so the detector returns 2. The control run with the
# clean Semgrep shows the same PR otherwise reaches the ask, so the deny comes
# from the detector failure alone.
build_pr_repo code app/greeting.py 'GREETING = "hello"' 'GREETING = "hello there"'
CODE_DIR="$REPO_DIR" CODE_BASE="$REPO_BASE" CODE_HEAD="$REPO_HEAD"
STUB=$(write_pr_stub case6 "$(pr_body "$(codex_section "$CODE_BASE" "$CODE_HEAD")")" "$CODE_HEAD" "$CODE_BASE" code)
expect_r514_ask "case 6a control (clean scan of a non-security code change)" "$(run_guard "$STUB" "$CODE_DIR" "$CLEAN_STUB")"
expect_r109_deny "case 6a (detector fails)" "$(run_guard "$STUB" "$CODE_DIR" "$CRASH_STUB")"

# Case 6b (fail closed): the PR head gh reports does not exist locally, so the
# range cannot be read; the checkout's own HEAD must not stand in for it.
MISSING_HEAD=$(printf 'deadbeef%.0s' 1 2 3 4 5)
STUB=$(write_pr_stub case6b "$(pr_body "$(codex_section "$DOCS_BASE" "$MISSING_HEAD")")" "$MISSING_HEAD" "$DOCS_BASE" docs)
expect_r109_deny "case 6b (PR head not resolvable)" "$(run_guard "$STUB" "$DOCS_DIR" "$CLEAN_STUB")"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate.test.sh"
