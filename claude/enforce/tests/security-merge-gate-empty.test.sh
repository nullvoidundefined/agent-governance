#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Verifies that the security merge gate in git-workflow-guard.sh (IAN-381,
# B-16b, rule R-109) refuses an empty Security review. On a PR whose range
# touches security code, a `## Security review` section with a valid reviewer,
# model, and range still denies the merge with a reason naming R-109 when it
# holds no findings table rows, no `Nothing found:` line, and no `No security
# control in range:` line, because such a section proves nothing was examined.
# A prose line such as `- Findings: none open.` does not count as a record.
# The same section carrying a `Nothing found:` line or a `No security control
# in range:` line reaches the plain R-514 ask.
#
# The setup mirrors security-merge-gate.test.sh: a throwaway repository whose
# `feature` branch touches app/middleware/cors_config.py, a gh stub answering
# with baseRefName and headRefOid, a clean Semgrep stub that lists its targets,
# a valid Codex review, and a scratch HOME.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST

failures=0
report_failure() { echo "FAIL security-merge-gate-empty.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL security-merge-gate-empty.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}

# A Semgrep stand-in reporting a complete clean scan: every target it was given
# is listed under paths.scanned.
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
# write_gh_stub <name> <json>: an executable gh stand-in that prints <json> as
# the `gh pr view` answer.
write_gh_stub() {
  local stub_path="$STUB_DIR/$1"
  printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\nexit 0\n' "$2" >"$stub_path"
  chmod +x "$stub_path"
  printf '%s' "$stub_path"
}

# write_pr_stub <name> <body> <head oid>: a gh stand-in answering for PR 42 of
# a same-repository `feature` branch into `main`, headed at <head oid>.
write_pr_stub() {
  local pr_json
  pr_json=$(jq -nc --arg body "$2" --arg head "$3" '{
    body: $body, labels: [], commits: [], headRefName: "feature", headRefOid: $head,
    baseRefName: "main", isCrossRepository: false, url: "https://github.com/example/app/pull/42"}')
  write_gh_stub "$1" "$pr_json"
}

# git_in <repo> <git args>...: git with a fixed identity and no signing.
git_in() {
  local repo="$1"
  shift
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1
}

# build_pr_repo <name> <path> <first content> <second content>: a repository
# whose `main` (and `origin/main`) holds a README-only base commit and whose
# `feature` branch adds <path> and then rewrites it; `main` stays checked out.
# Sets REPO_DIR, REPO_BASE, and REPO_HEAD.
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
    { echo "FAIL security-merge-gate-empty.test.sh: fixture setup could not point origin/main at the base in $name"; exit 1; }
}

# codex_section <base> <head>: a valid R-517 `## Codex review` section.
codex_section() {
  printf '## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n- No findings; checked B-16b.\n' "$1" "$2"
}

# security_header <base> <head>: a `## Security review` section with a valid
# reviewer, the expected model, and a current range, and nothing else.
security_header() {
  printf '## Security review\n- reviewer: security-reviewer\n- model: %s\n- range: %.7s..%.7s\n' "$EXPECTED_MODEL" "$1" "$2"
}

# pr_body <section>...: a PR body holding a summary, the given sections, and a
# testing section.
pr_body() {
  local section
  printf '## Summary\nWork.\n\n'
  for section in "$@"; do printf '%s\n' "$section"; done
  printf '## Testing\nGreen.\n'
}

# run_guard <gh stub> <repo>: the hook's JSON output for
# `gh pr merge 42 --squash` run from <repo> with the clean Semgrep stub.
run_guard() {
  jq -nc --arg c 'gh pr merge 42 --squash' --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
    CLAUDE_GH_CMD="$1" CLAUDE_SEMGREP_CMD="$CLEAN_STUB" "$HOOK" 2>/dev/null
}

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
  case "$reason" in *R-109*) ;; *) report_failure "$1: deny reason does not name R-109: $reason" ;; esac
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
SEC_DIR="$REPO_DIR" SEC_BASE="$REPO_BASE" SEC_HEAD="$REPO_HEAD"
SEC_CODEX=$(codex_section "$SEC_BASE" "$SEC_HEAD")
SEC_HEADER=$(security_header "$SEC_BASE" "$SEC_HEAD")

# Case 1: a prose findings line is not a record of what was examined.
STUB=$(write_pr_stub case1 "$(pr_body "$SEC_CODEX" "$(printf '%s\n- Findings: none open. Everything looked fine.\n' "$SEC_HEADER")")" "$SEC_HEAD")
expect_r109_deny "case 1 (prose findings line only)" "$(run_guard "$STUB" "$SEC_DIR")"

# Case 2: reviewer, model, and range with nothing after them.
STUB=$(write_pr_stub case2 "$(pr_body "$SEC_CODEX" "$SEC_HEADER")" "$SEC_HEAD")
expect_r109_deny "case 2 (header only)" "$(run_guard "$STUB" "$SEC_DIR")"

# Case 3 (control): the same header plus a `Nothing found:` line reaches the ask.
STUB=$(write_pr_stub case3 "$(pr_body "$SEC_CODEX" "$(printf '%s\n\nNothing found: CORS: sources env CORS_ORIGIN: tried *, null\n' "$SEC_HEADER")")" "$SEC_HEAD")
expect_r514_ask "case 3 control (Nothing found line)" "$(run_guard "$STUB" "$SEC_DIR")"

# Case 4 (control): the same header plus a `No security control in range:` line.
STUB=$(write_pr_stub case4 "$(pr_body "$SEC_CODEX" "$(printf '%s\n\nNo security control in range: docs/notes.md\n' "$SEC_HEADER")")" "$SEC_HEAD")
expect_r514_ask "case 4 control (No security control in range line)" "$(run_guard "$STUB" "$SEC_DIR")"

if [ "$failures" -gt 0 ]; then
  echo "security-merge-gate-empty.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS security-merge-gate-empty.test.sh"
