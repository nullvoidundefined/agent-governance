#!/usr/bin/env bash
# Shard: slow
# Covers: hook:git-workflow-guard
# Verifies that the merge gate in git-workflow-guard.sh accepts an R-517
# `## Codex review` whose range head is an older PR commit when every later
# commit is a clean merge of the base branch or a commit the section's
# findings table marks `fixed <sha>` (IAN-568, I6: every fix or base merge
# moved the head and forced another review round), and an R-109
# `## Security review` whose later commits are clean base merges only: the
# `fixed <sha>` cell is self-attested in the mutable PR body, so a security
# fix commit needs a new review round whose range ends at the head (R-109 r1
# #3 on PR #182). Every other later commit is denied:
#
#   base merge, Codex        main gains code and is merged into the branch
#                            after the review: reaches the R-514 ask.
#   evil base merge, Codex   the same merge also adds its own code: denied,
#                            R-517.
#   listed fix, Codex        a fix commit named `fixed <sha>` in the Codex
#                            findings table: reaches the R-514 ask.
#   unlisted sha, Codex      the commit is named in the table but in a cell
#                            that does not say fixed: denied, R-517.
#   listed fix, Security     a fix commit named `fixed <sha>` in the Security
#                            findings table after the recorded review head:
#                            denied, R-109.
#   base merge, Security     a clean base merge, and nothing else, after the
#                            recorded review head: reaches the R-514 ask.
#   fix and base merge,      a listed fix commit and then a clean base merge
#   Security                 after the recorded review head: denied, R-109.
#   neither, Security        an unlisted code commit after the recorded
#                            review head: denied, R-109.
#
# The harness (stubbed gh, a repository per case, clean Semgrep) is copied
# from git-workflow-guard-docs-tail.test.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST
# An inherited repository selection (a hook run from a linked worktree exports
# these) would point every `git -C` below at the calling repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

failures=0
report_failure() { echo "FAIL git-workflow-guard-reviewed-tail.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

# The one key the model is read from (invariant: no hardcoded model name).
EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL git-workflow-guard-reviewed-tail.test.sh: $MODEL_FILE has no securityReviewModel string"
  exit 1
}

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
    { echo "FAIL git-workflow-guard-reviewed-tail.test.sh: fixture setup could not point origin/main at the base in $name"; exit 1; }
  git_in "$REPO_DIR" remote set-url origin "https://github.com/fixture/$name.git"
  git_in "$REPO_DIR" remote set-url --push origin "$origin_dir"
  [ "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" = "https://github.com/fixture/$name.git" ] ||
    { echo "FAIL git-workflow-guard-reviewed-tail.test.sh: fixture setup could not point origin at https://github.com/fixture/$name.git"; exit 1; }
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


# expect_r517_deny <case> <output>: the merge is denied and the reason names R-517.
expect_r517_deny() {
  local decision reason
  decision=$(read_decision "$2")
  reason=$(read_reason "$2")
  [ "$decision" = deny ] || { report_failure "$1: expected deny, got $decision ($reason)"; return 1; }
  case "$reason" in *R-517*) ;; *) report_failure "$1: deny reason does not name R-517: $reason" ;; esac
}

# add_commit <repo> <path> <content> <message>: commits one file on feature,
# pushes, returns to main, and prints the new head.
add_commit() {
  git_in "$1" checkout -q feature
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git_in "$1" add -A
  git_in "$1" commit -q -m "$4"
  git -C "$1" rev-parse HEAD
  git_in "$1" push -q origin feature
  git_in "$1" checkout -q main
}

# advance_base <repo> <path> <content>: commits <path> on main, moves
# origin/main to it (the fixture's origin URL is not fetchable, so the
# remote-tracking ref is set directly), and prints the new base.
advance_base() {
  git_in "$1" checkout -q main
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git_in "$1" add -A
  git_in "$1" commit -q -m "feat: work on main"
  git_in "$1" update-ref refs/remotes/origin/main HEAD
  git -C "$1" rev-parse HEAD
}

# merge_base_into_feature <repo> [<extra path>]: merges main into feature,
# adding <extra path> to the merge commit when given (an evil merge), and
# prints the merge commit.
merge_base_into_feature() {
  git_in "$1" checkout -q feature
  if [ -n "${2:-}" ]; then
    git_in "$1" merge -q --no-ff --no-commit main
    mkdir -p "$(dirname "$1/$2")"
    printf 'EVIL = 1\n' > "$1/$2"
    git_in "$1" add -A
    git_in "$1" commit -q -m "merge main"
  else
    git_in "$1" merge -q --no-ff --no-edit main
  fi
  git -C "$1" rev-parse HEAD
  git_in "$1" push -q origin feature
  git_in "$1" checkout -q main
}

# codex_table_section <base> <head> <status cell>: a `## Codex review` section
# in the short form (reviewer, model, range, findings with dispositions) whose
# one finding row carries <status cell>.
codex_table_section() {
  printf '## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..%.7s\n\n| # | Severity | Finding | Disposition |\n|---|---|---|---|\n| 1 | MEDIUM | greeting unescaped | %s |\n' "$1" "$2" "$3"
}

SECURITY_ARTEFACT=docs/reviews/security-review.json

# security_table_section <base> <head> <status cell>: a `## Security review`
# section on the strongest model whose one MEDIUM finding row carries
# <status cell>, naming the committed artefact.
security_table_section() {
  printf '## Security review\n- reviewer: security-reviewer\n- model: %s\n- range: %.7s..%.7s\n- artefact: %s\n\n| # | Severity | Control | Source | Worst value tried | Evidence | Fix | Status |\n|---|---|---|---|---|---|---|---|\n| 1 | MEDIUM | CORS | env CORS_ORIGIN | * | origins list | narrowed | %s |\n' \
    "$EXPECTED_MODEL" "$1" "$2" "$SECURITY_ARTEFACT" "$3"
}

# build_security_review_repo <name>: a PR changing a CORS config, then a
# commit adding the Security review artefact (one MEDIUM finding), recorded in
# the ledger with that commit checked out. Sets SR_DIR, SR_BASE, SR_CHANGE
# (the PR commit narrowing the config, inside the reviewed range), and
# SR_REVIEWED (the recorded review head).
build_security_review_repo() {
  build_pr_repo "$1" app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
    'ALLOWED_ORIGINS = ["*"]'
  SR_DIR="$REPO_DIR" SR_BASE="$REPO_BASE" SR_CHANGE="$REPO_HEAD"
  git_in "$SR_DIR" checkout -q feature
  mkdir -p "$SR_DIR/docs/reviews"
  printf '%s\n' '{"findings":[{"id":1,"severity":"MEDIUM"}]}' > "$SR_DIR/$SECURITY_ARTEFACT"
  git_in "$SR_DIR" add docs
  git_in "$SR_DIR" commit -q -m "docs: security review artefact"
  SR_REVIEWED=$(git -C "$SR_DIR" rev-parse HEAD)
  git_in "$SR_DIR" push -q origin feature
  (cd "$SR_DIR" && bash "$RECORD_SCRIPT" "$SECURITY_ARTEFACT" >/dev/null 2>&1) ||
    report_failure "setup: security-review-record.sh could not record $SECURITY_ARTEFACT in $1"
  git_in "$SR_DIR" checkout -q main
}

# --- 1. a clean base merge after the Codex review ---------------------------
build_pr_repo basemerge app/greeting.py 'GREETING = "hello"' 'GREETING = "hi"'
B_DIR="$REPO_DIR" B_BASE="$REPO_BASE" B_REVIEWED="$REPO_HEAD"
B_NEW_BASE=$(advance_base "$B_DIR" app/main_work.py 'MAIN = 1')
B_HEAD=$(merge_base_into_feature "$B_DIR")
STUB=$(write_pr_stub basemerge "$(pr_body "$(codex_section "$B_BASE" "$B_REVIEWED")")" "$B_HEAD" "$B_NEW_BASE" basemerge)
expect_r514_ask "clean base merge after the Codex review" "$(run_guard "$STUB" "$B_DIR" "$CLEAN_STUB")"

# --- 2. a base merge that adds its own code ---------------------------------
build_pr_repo evilbase app/greeting.py 'GREETING = "hello"' 'GREETING = "yo"'
E_DIR="$REPO_DIR" E_BASE="$REPO_BASE" E_REVIEWED="$REPO_HEAD"
E_NEW_BASE=$(advance_base "$E_DIR" app/main_work.py 'MAIN = 2')
E_HEAD=$(merge_base_into_feature "$E_DIR" app/evil.py)
STUB=$(write_pr_stub evilbase "$(pr_body "$(codex_section "$E_BASE" "$E_REVIEWED")")" "$E_HEAD" "$E_NEW_BASE" evilbase)
expect_r517_deny "base merge carrying its own code" "$(run_guard "$STUB" "$E_DIR" "$CLEAN_STUB")"

# --- 3. a fix commit listed as fixed in the Codex findings table ------------
build_pr_repo codexfix app/greeting.py 'GREETING = "hello"' 'GREETING = "hey"'
F_DIR="$REPO_DIR" F_BASE="$REPO_BASE" F_REVIEWED="$REPO_HEAD"
F_HEAD=$(add_commit "$F_DIR" app/greeting.py 'GREETING = "hey" # escaped' "fix: escape the greeting")
STUB=$(write_pr_stub codexfix "$(pr_body "$(codex_table_section "$F_BASE" "$F_REVIEWED" "fixed $(printf '%.7s' "$F_HEAD")")")" "$F_HEAD" "$F_BASE" codexfix)
expect_r514_ask "fix commit listed fixed in the Codex table" "$(run_guard "$STUB" "$F_DIR" "$CLEAN_STUB")"

# --- 4. the same commit named in a cell that does not say fixed -------------
STUB=$(write_pr_stub codexunlisted "$(pr_body "$(codex_table_section "$F_BASE" "$F_REVIEWED" "deferred, see $(printf '%.7s' "$F_HEAD")")")" "$F_HEAD" "$F_BASE" codexfix)
expect_r517_deny "commit named outside a fixed cell" "$(run_guard "$STUB" "$F_DIR" "$CLEAN_STUB")"

# --- 5. a fix commit listed as fixed in the Security findings table ---------
build_security_review_repo secfix
S_DIR="$SR_DIR" S_BASE="$SR_BASE" S_REVIEWED="$SR_REVIEWED"
S_HEAD=$(add_commit "$S_DIR" app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' "fix: narrow the origins")
S_FIXED="fixed $(printf '%.7s' "$S_HEAD")"
S_BODY=$(pr_body "$(codex_table_section "$S_BASE" "$S_REVIEWED" "$S_FIXED")" "$(security_table_section "$S_BASE" "$S_REVIEWED" "$S_FIXED")")
STUB=$(write_pr_stub secfix "$S_BODY" "$S_HEAD" "$S_BASE" secfix)
expect_r109_deny "fix commit listed fixed in the Security table" \
  "$(run_guard "$STUB" "$S_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $S_HEAD")"

# --- 6. a clean base merge, and nothing else, after the Security review -----
# The finding's fix is the reviewed PR commit, inside the review's own range.
build_security_review_repo secmerge
M_DIR="$SR_DIR" M_BASE="$SR_BASE" M_REVIEWED="$SR_REVIEWED"
M_NEW_BASE=$(advance_base "$M_DIR" app/main_work.py 'MAIN = 3')
M_HEAD=$(merge_base_into_feature "$M_DIR")
M_FIXED="fixed $(printf '%.7s' "$SR_CHANGE")"
M_BODY=$(pr_body "$(codex_table_section "$M_BASE" "$M_REVIEWED" "$M_FIXED")" "$(security_table_section "$M_BASE" "$M_REVIEWED" "$M_FIXED")")
STUB=$(write_pr_stub secmerge "$M_BODY" "$M_HEAD" "$M_NEW_BASE" secmerge)
expect_r514_ask "clean base merge only after the Security review" \
  "$(run_guard "$STUB" "$M_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $M_HEAD")"

# --- 6b. a listed fix and then a clean base merge after the Security review --
build_security_review_repo secfixmerge
X_DIR="$SR_DIR" X_BASE="$SR_BASE" X_REVIEWED="$SR_REVIEWED"
X_FIX=$(add_commit "$X_DIR" app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' "fix: narrow the origins")
X_NEW_BASE=$(advance_base "$X_DIR" app/main_work.py 'MAIN = 4')
X_HEAD=$(merge_base_into_feature "$X_DIR")
X_FIXED="fixed $(printf '%.7s' "$X_FIX")"
X_BODY=$(pr_body "$(codex_table_section "$X_BASE" "$X_REVIEWED" "$X_FIXED")" "$(security_table_section "$X_BASE" "$X_REVIEWED" "$X_FIXED")")
STUB=$(write_pr_stub secfixmerge "$X_BODY" "$X_HEAD" "$X_NEW_BASE" secfixmerge)
expect_r109_deny "fix and clean base merge after the Security review" \
  "$(run_guard "$STUB" "$X_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $X_HEAD")"

# --- 7. an unlisted code commit after the Security review -------------------
build_security_review_repo secneither
N_DIR="$SR_DIR" N_BASE="$SR_BASE" N_REVIEWED="$SR_REVIEWED"
N_FIX=$(add_commit "$N_DIR" app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' "fix: narrow the origins")
N_HEAD=$(add_commit "$N_DIR" app/middleware/cors_extra.py 'EXTRA_ORIGINS = ["*"]' "feat: unreviewed origins")
N_FIXED="fixed $(printf '%.7s' "$N_FIX")"
N_BODY=$(pr_body "$(codex_section "$N_BASE" "$N_HEAD")" "$(security_table_section "$N_BASE" "$N_REVIEWED" "$N_FIXED")")
STUB=$(write_pr_stub secneither "$N_BODY" "$N_HEAD" "$N_BASE" secneither)
expect_r109_deny "unlisted code commit after the Security review" \
  "$(run_guard "$STUB" "$N_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $N_HEAD")"

if [ "$failures" -gt 0 ]; then
  echo "git-workflow-guard-reviewed-tail.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS git-workflow-guard-reviewed-tail.test.sh"
