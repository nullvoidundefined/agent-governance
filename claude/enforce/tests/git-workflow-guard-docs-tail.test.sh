#!/usr/bin/env bash
# Shard: slow
# Covers: hook:git-workflow-guard
# Verifies that the merge gate in git-workflow-guard.sh accepts an R-517
# `## Codex review` whose range head is an older PR commit when every commit
# after it changes only the repository's top-level docs/ tree (IAN-516, owner
# decision 2026-09-30), and that the R-109 `## Security review` keeps the
# exact-head rule: the exception was narrowed to R-517 after five review rounds
# found binding the security artefact unbounded, so cases 7, 15, 18, and 19
# now prove a docs-only tail never relaxes R-109. A PR note, the R-109
# artefact JSON, or a handoff committed after a review forced another full
# review round: 3 of 4 rounds on IAN-352 and a 58-minute confirming R-109 round
# on PR #169. Everything else still needs a review of the exact head:
#
#   docs-only tail           Codex review of the code commit, a docs/ commit
#                            after it: reaches the R-514 ask.
#   code in the tail         a later commit also changes app/: denied, R-517.
#   claude/docs/ in the tail a docs/ tree that is not top-level: denied.
#   symlink in the tail      a docs/ symlink pointing into app/: denied.
#   not an ancestor          the review head is a commit off the PR's branch:
#                            denied.
#   unknown review head      a review head the checkout does not hold: denied.
#   security, docs tail      Codex and Security reviews of the code commit,
#                            the artefact committed after both: denied,
#                            R-109, because the exception covers R-517 only
#                            (owner decision 2026-09-30 after five review
#                            rounds found the artefact half unbounded).
#   security, R-517 tail     the same PR with the Security review at the
#                            exact head and the Codex review older: R-514
#                            asks.
#   security, code tail      the Security review is older than a later code
#                            change: denied, R-109.
#
# The PR #172 reviews (Codex and the R-109 reviewer) added:
#
#   hex-named branch or tag  a ref named like an object prefix, pointing at
#                            the PR head, is not a review head: denied.
#   base as review head      a docs-only PR whose review range ends at the
#                            base reviewed nothing of the PR: denied.
#   code then revert         a tail that adds code and reverts it before a
#                            docs commit: denied, since every tail commit is
#                            checked, not the net tree.
#   merge of main            a tail merging main's code: denied.
#   executable docs file     a docs/ file with mode 100755: denied.
#   ignored submodule        a docs/ gitlink under diff.ignoreSubmodules=all:
#                            denied.
#   second artefact          the reviewed range already added an artefact
#                            with an open row; the tail adds a clean one
#                            beside it and the section names that: denied,
#                            R-109 (round 2 of the R-109 review).
#   artefact elsewhere       as above, but the reviewed artefact is saved
#                            as .txt in another docs/ directory and the
#                            clean one elsewhere: denied, R-109 (Codex
#                            round 4: no extension or name can be trusted).
#   merge diffs switched off code arriving only in a merge result under
#                            log.diffMerges=off: denied (Codex round 3).
#   replacement object       refs/replace makes the PR head look docs-only
#                            while the real head changes code: denied.
#   docs edit and delete     a tail that modifies one docs/ file and deletes
#                            another: reaches the R-514 ask.
#   artefact rewritten       a tail that edits an existing
#                            docs/security-reviews/ file: denied, R-109; the
#                            artefact may be added after the review, never
#                            changed.
#
# The harness (stubbed gh, a repository per case, clean Semgrep) is copied
# from security-merge-gate.test.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
unset CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD CLAUDE_SEMGREP_CMD GH_REPO GH_HOST
# An inherited repository selection (a hook run from a linked worktree exports
# these) would point every `git -C` below at the calling repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

failures=0
report_failure() { echo "FAIL git-workflow-guard-docs-tail.test.sh: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1

# The one key the model is read from (invariant: no hardcoded model name).
EXPECTED_MODEL=$(jq -er '.securityReviewModel | strings | select(length > 0)' "$MODEL_FILE" 2>/dev/null) || {
  echo "FAIL git-workflow-guard-docs-tail.test.sh: $MODEL_FILE has no securityReviewModel string"
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
    { echo "FAIL git-workflow-guard-docs-tail.test.sh: fixture setup could not point origin/main at the base in $name"; exit 1; }
  git_in "$REPO_DIR" remote set-url origin "https://github.com/fixture/$name.git"
  git_in "$REPO_DIR" remote set-url --push origin "$origin_dir"
  [ "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" = "https://github.com/fixture/$name.git" ] ||
    { echo "FAIL git-workflow-guard-docs-tail.test.sh: fixture setup could not point origin at https://github.com/fixture/$name.git"; exit 1; }
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

# --- 1. docs-only tail after the Codex review -------------------------------
build_pr_repo tail app/greeting.py 'GREETING = "hello"' 'GREETING = "hello there"'
T_DIR="$REPO_DIR" T_BASE="$REPO_BASE" T_REVIEWED="$REPO_HEAD"
T_HEAD=$(add_commit "$T_DIR" docs/prs/note.md 'PR note.' "docs: PR note")
STUB=$(write_pr_stub tail1 "$(pr_body "$(codex_section "$T_BASE" "$T_REVIEWED")")" "$T_HEAD" "$T_BASE" tail)
expect_r514_ask "docs-only tail after the Codex review" "$(run_guard "$STUB" "$T_DIR" "$CLEAN_STUB")"

# --- 2. code in the tail ----------------------------------------------------
T2_HEAD=$(add_commit "$T_DIR" app/other.py 'OTHER = 1' "feat: more code")
STUB=$(write_pr_stub tail2 "$(pr_body "$(codex_section "$T_BASE" "$T_REVIEWED")")" "$T2_HEAD" "$T_BASE" tail)
expect_r517_deny "code change after the Codex review" "$(run_guard "$STUB" "$T_DIR" "$CLEAN_STUB")"

# --- 3. claude/docs/ in the tail --------------------------------------------
build_pr_repo nested app/greeting.py 'GREETING = "hello"' 'GREETING = "hi"'
N_DIR="$REPO_DIR" N_BASE="$REPO_BASE" N_REVIEWED="$REPO_HEAD"
N_HEAD=$(add_commit "$N_DIR" claude/docs/rule.md 'A rule.' "docs: nested")
STUB=$(write_pr_stub nested "$(pr_body "$(codex_section "$N_BASE" "$N_REVIEWED")")" "$N_HEAD" "$N_BASE" nested)
expect_r517_deny "claude/docs/ change after the Codex review" "$(run_guard "$STUB" "$N_DIR" "$CLEAN_STUB")"

# --- 4. a docs/ symlink in the tail -----------------------------------------
build_pr_repo link app/greeting.py 'GREETING = "hello"' 'GREETING = "hey"'
L_DIR="$REPO_DIR" L_BASE="$REPO_BASE" L_REVIEWED="$REPO_HEAD"
git_in "$L_DIR" checkout -q feature
mkdir -p "$L_DIR/docs"
ln -s ../app/greeting.py "$L_DIR/docs/greeting.py"
git_in "$L_DIR" add -A
git_in "$L_DIR" commit -q -m "docs: link"
L_HEAD=$(git -C "$L_DIR" rev-parse HEAD)
git_in "$L_DIR" push -q origin feature
git_in "$L_DIR" checkout -q main
STUB=$(write_pr_stub link "$(pr_body "$(codex_section "$L_BASE" "$L_REVIEWED")")" "$L_HEAD" "$L_BASE" link)
expect_r517_deny "docs/ symlink after the Codex review" "$(run_guard "$STUB" "$L_DIR" "$CLEAN_STUB")"

# --- 5. the review head is not an ancestor of the PR head -------------------
git_in "$T_DIR" checkout -q -b side "$T_BASE"
printf 'side\n' > "$T_DIR/side.txt"
git_in "$T_DIR" add -A
git_in "$T_DIR" commit -q -m "chore: side"
SIDE=$(git -C "$T_DIR" rev-parse HEAD)
git_in "$T_DIR" checkout -q main
STUB=$(write_pr_stub tail5 "$(pr_body "$(codex_section "$T_BASE" "$SIDE")")" "$T_HEAD" "$T_BASE" tail)
expect_r517_deny "review head off the PR branch" "$(run_guard "$STUB" "$T_DIR" "$CLEAN_STUB")"

# --- 6. a review head the checkout does not hold ----------------------------
STUB=$(write_pr_stub tail6 "$(pr_body "$(codex_section "$T_BASE" "abcdef0123456")")" "$T_HEAD" "$T_BASE" tail)
expect_r517_deny "unknown review head" "$(run_guard "$STUB" "$T_DIR" "$CLEAN_STUB")"

# --- 7. security review, artefact committed after both reviews --------------
build_pr_repo sectail app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
  'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]'
S_DIR="$REPO_DIR" S_BASE="$REPO_BASE" S_REVIEWED="$REPO_HEAD"
git_in "$S_DIR" checkout -q feature
mkdir -p "$S_DIR/docs/reviews"
printf '%s\n' '{"findings":[]}' > "$S_DIR/$ARTEFACT_PATH"
git_in "$S_DIR" add docs
git_in "$S_DIR" commit -q -m "docs: security review artefact"
S_HEAD=$(git -C "$S_DIR" rev-parse HEAD)
git_in "$S_DIR" push -q origin feature
(cd "$S_DIR" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1) ||
  report_failure "setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
git_in "$S_DIR" checkout -q main
S_BODY=$(pr_body "$(codex_section "$S_BASE" "$S_REVIEWED")" "$(security_section security-reviewer "$EXPECTED_MODEL" "$S_BASE" "$S_REVIEWED")")
STUB=$(write_pr_stub sectail "$S_BODY" "$S_HEAD" "$S_BASE" sectail)
expect_r109_deny "security review before a docs-only artefact commit" \
  "$(run_guard "$STUB" "$S_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $S_HEAD")"
S_BODY=$(pr_body "$(codex_section "$S_BASE" "$S_REVIEWED")" "$(security_section security-reviewer "$EXPECTED_MODEL" "$S_BASE" "$S_HEAD")")
STUB=$(write_pr_stub sectail2 "$S_BODY" "$S_HEAD" "$S_BASE" sectail)
expect_r514_ask "security review at the head, Codex review before a docs tail" \
  "$(run_guard "$STUB" "$S_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $S_HEAD")"

# --- 8. security review older than a later code change ----------------------
build_pr_repo seccode app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
  'ALLOWED_ORIGINS = ["https://app.example.com", "https://admin.example.com"]'
C_DIR="$REPO_DIR" C_BASE="$REPO_BASE" C_FIRST="$REPO_FIRST"
git_in "$C_DIR" checkout -q feature
mkdir -p "$C_DIR/docs/reviews"
printf '%s\n' '{"findings":[]}' > "$C_DIR/$ARTEFACT_PATH"
git_in "$C_DIR" add docs
git_in "$C_DIR" commit -q -m "docs: security review artefact"
C_HEAD=$(git -C "$C_DIR" rev-parse HEAD)
git_in "$C_DIR" push -q origin feature
(cd "$C_DIR" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1) ||
  report_failure "setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
git_in "$C_DIR" checkout -q main
C_BODY=$(pr_body "$(codex_section "$C_BASE" "$C_HEAD")" "$(security_section security-reviewer "$EXPECTED_MODEL" "$C_BASE" "$C_FIRST")")
STUB=$(write_pr_stub seccode "$C_BODY" "$C_HEAD" "$C_BASE" seccode)
expect_r109_deny "security review older than a code change" \
  "$(run_guard "$STUB" "$C_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $C_HEAD")"

# --- 9. a hex-named branch and tag pointing at the PR head ------------------
build_pr_repo hexref app/greeting.py 'GREETING = "hello"' 'GREETING = "hola"'
X_DIR="$REPO_DIR" X_BASE="$REPO_BASE" X_REVIEWED="$REPO_FIRST"
X_HEAD=$(add_commit "$X_DIR" app/other.py 'OTHER = 2' "feat: unreviewed code")
git_in "$X_DIR" branch deadbee1 "$X_HEAD"
STUB=$(write_pr_stub hexbranch "$(pr_body "$(printf '## Codex review\n- reviewer: pr-reviewer\n- model: sonnet\n- range: %.7s..deadbee1\n' "$X_BASE")")" "$X_HEAD" "$X_BASE" hexref)
expect_r517_deny "hex-named branch as review head" "$(run_guard "$STUB" "$X_DIR" "$CLEAN_STUB")"
TAG_NAME=$(printf '%.7s' "$X_REVIEWED")
git_in "$X_DIR" tag "$TAG_NAME" "$X_HEAD"
STUB=$(write_pr_stub hextag "$(pr_body "$(codex_section "$X_BASE" "$X_REVIEWED")")" "$X_HEAD" "$X_BASE" hexref)
expect_r517_deny "tag named like the reviewed commit" "$(run_guard "$STUB" "$X_DIR" "$CLEAN_STUB")"

# --- 10. the base as the review head on a docs-only PR ----------------------
build_pr_repo docsonly docs/guide.md 'Read the guide.' 'Read the guide twice.'
D_DIR="$REPO_DIR" D_BASE="$REPO_BASE" D_HEAD="$REPO_HEAD"
STUB=$(write_pr_stub basehead "$(pr_body "$(codex_section "$D_BASE" "$D_BASE")")" "$D_HEAD" "$D_BASE" docsonly)
expect_r517_deny "base as review head" "$(run_guard "$STUB" "$D_DIR" "$CLEAN_STUB")"

# --- 11. code added then reverted in the tail -------------------------------
build_pr_repo revert app/greeting.py 'GREETING = "hello"' 'GREETING = "salut"'
V_DIR="$REPO_DIR" V_BASE="$REPO_BASE" V_REVIEWED="$REPO_HEAD"
add_commit "$V_DIR" app/evil.py 'EVIL = 1' "feat: code" >/dev/null
git_in "$V_DIR" checkout -q feature
git_in "$V_DIR" rm -q app/evil.py
git_in "$V_DIR" commit -q -m "revert: code"
git_in "$V_DIR" push -q origin feature
git_in "$V_DIR" checkout -q main
V_HEAD=$(add_commit "$V_DIR" docs/prs/note.md 'Note.' "docs: note")
STUB=$(write_pr_stub revert "$(pr_body "$(codex_section "$V_BASE" "$V_REVIEWED")")" "$V_HEAD" "$V_BASE" revert)
expect_r517_deny "code then revert in the tail" "$(run_guard "$STUB" "$V_DIR" "$CLEAN_STUB")"

# --- 12. a merge of main in the tail ----------------------------------------
build_pr_repo mergemain app/greeting.py 'GREETING = "hello"' 'GREETING = "ciao"'
M_DIR="$REPO_DIR" M_BASE="$REPO_BASE" M_REVIEWED="$REPO_HEAD"
git_in "$M_DIR" checkout -q -b other "$M_BASE"
printf 'X = 1\n' > "$M_DIR/app_main.py"
git_in "$M_DIR" add -A
git_in "$M_DIR" commit -q -m "feat: other work"
git_in "$M_DIR" checkout -q feature
git_in "$M_DIR" merge -q --no-edit other
M_HEAD=$(git -C "$M_DIR" rev-parse HEAD)
git_in "$M_DIR" push -q origin feature
git_in "$M_DIR" checkout -q main
STUB=$(write_pr_stub mergemain "$(pr_body "$(codex_section "$M_BASE" "$M_REVIEWED")")" "$M_HEAD" "$M_BASE" mergemain)
expect_r517_deny "merge carrying code in the tail" "$(run_guard "$STUB" "$M_DIR" "$CLEAN_STUB")"

# --- 13. an executable docs file in the tail --------------------------------
build_pr_repo execdoc app/greeting.py 'GREETING = "hello"' 'GREETING = "hej"'
E_DIR="$REPO_DIR" E_BASE="$REPO_BASE" E_REVIEWED="$REPO_HEAD"
git_in "$E_DIR" checkout -q feature
mkdir -p "$E_DIR/docs"
printf '#!/bin/sh\necho hi\n' > "$E_DIR/docs/run.sh"
chmod +x "$E_DIR/docs/run.sh"
git_in "$E_DIR" add -A
git_in "$E_DIR" commit -q -m "docs: script"
E_HEAD=$(git -C "$E_DIR" rev-parse HEAD)
git_in "$E_DIR" push -q origin feature
git_in "$E_DIR" checkout -q main
STUB=$(write_pr_stub execdoc "$(pr_body "$(codex_section "$E_BASE" "$E_REVIEWED")")" "$E_HEAD" "$E_BASE" execdoc)
expect_r517_deny "executable docs file in the tail" "$(run_guard "$STUB" "$E_DIR" "$CLEAN_STUB")"

# --- 14. a docs/ gitlink hidden by diff.ignoreSubmodules --------------------
build_pr_repo submod app/greeting.py 'GREETING = "hello"' 'GREETING = "hallo"'
G_DIR="$REPO_DIR" G_BASE="$REPO_BASE" G_REVIEWED="$REPO_HEAD"
git_in "$G_DIR" config diff.ignoreSubmodules all
git_in "$G_DIR" checkout -q feature
git_in "$G_DIR" update-index --add --cacheinfo "160000,$G_BASE,docs/vendor"
git_in "$G_DIR" commit -q -m "docs: vendor link"
G_HEAD=$(git -C "$G_DIR" rev-parse HEAD)
git_in "$G_DIR" push -q origin feature
git_in "$G_DIR" checkout -q -f main
STUB=$(write_pr_stub submod "$(pr_body "$(codex_section "$G_BASE" "$G_REVIEWED")")" "$G_HEAD" "$G_BASE" submod)
expect_r517_deny "docs gitlink under ignoreSubmodules" "$(run_guard "$STUB" "$G_DIR" "$CLEAN_STUB")"

# --- 15. the security artefact rewritten after the review -------------------
build_pr_repo rewrite app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
  'ALLOWED_ORIGINS = ["https://app.example.com", "https://ops.example.com"]'
W_DIR="$REPO_DIR" W_BASE="$REPO_BASE"
git_in "$W_DIR" checkout -q feature
mkdir -p "$W_DIR/docs/reviews"
printf '%s\n' '{"findings":[{"id":1,"severity":"HIGH","status":"open"}]}' > "$W_DIR/$ARTEFACT_PATH"
git_in "$W_DIR" add docs
git_in "$W_DIR" commit -q -m "docs: artefact"
W_REVIEWED=$(git -C "$W_DIR" rev-parse HEAD)
printf '%s\n' '{"findings":[]}' > "$W_DIR/$ARTEFACT_PATH"
git_in "$W_DIR" add docs
git_in "$W_DIR" commit -q -m "docs: artefact rewritten"
W_HEAD=$(git -C "$W_DIR" rev-parse HEAD)
git_in "$W_DIR" push -q origin feature
(cd "$W_DIR" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1) ||
  report_failure "setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
git_in "$W_DIR" checkout -q main
W_BODY=$(pr_body "$(codex_section "$W_BASE" "$W_HEAD")" "$(security_section security-reviewer "$EXPECTED_MODEL" "$W_BASE" "$W_REVIEWED")")
STUB=$(write_pr_stub rewrite "$W_BODY" "$W_HEAD" "$W_BASE" rewrite)
expect_r109_deny "artefact rewritten after the review" \
  "$(run_guard "$STUB" "$W_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $W_HEAD")"

# --- 16. a replacement object disguising the PR head ------------------------
build_pr_repo replace app/greeting.py 'GREETING = "hello"' 'GREETING = "moi"'
P_DIR="$REPO_DIR" P_BASE="$REPO_BASE" P_REVIEWED="$REPO_HEAD"
P_HEAD=$(add_commit "$P_DIR" app/evil.py 'EVIL = 1' "feat: unreviewed code")
git_in "$P_DIR" checkout -q -b decoy "$P_REVIEWED"
mkdir -p "$P_DIR/docs"
printf 'decoy\n' > "$P_DIR/docs/decoy.md"
git_in "$P_DIR" add -A
git_in "$P_DIR" commit -q -m "docs: decoy"
DECOY=$(git -C "$P_DIR" rev-parse HEAD)
git_in "$P_DIR" checkout -q main
git_in "$P_DIR" replace "$P_HEAD" "$DECOY"
STUB=$(write_pr_stub replace "$(pr_body "$(codex_section "$P_BASE" "$P_REVIEWED")")" "$P_HEAD" "$P_BASE" replace)
expect_r517_deny "replacement object disguising the head" "$(run_guard "$STUB" "$P_DIR" "$CLEAN_STUB")"

# --- 17. a tail that modifies and deletes docs files ------------------------
build_pr_repo docsedit app/greeting.py 'GREETING = "hello"' 'GREETING = "aloha"'
Q_DIR="$REPO_DIR" Q_BASE="$REPO_BASE"
add_commit "$Q_DIR" docs/a.md 'A.' "docs: a" >/dev/null
Q_REVIEWED=$(add_commit "$Q_DIR" docs/b.md 'B.' "docs: b")
add_commit "$Q_DIR" docs/a.md 'A, revised.' "docs: revise a" >/dev/null
git_in "$Q_DIR" checkout -q feature
git_in "$Q_DIR" rm -q docs/b.md
git_in "$Q_DIR" commit -q -m "docs: drop b"
Q_HEAD=$(git -C "$Q_DIR" rev-parse HEAD)
git_in "$Q_DIR" push -q origin feature
git_in "$Q_DIR" checkout -q main
STUB=$(write_pr_stub docsedit "$(pr_body "$(codex_section "$Q_BASE" "$Q_REVIEWED")")" "$Q_HEAD" "$Q_BASE" docsedit)
expect_r514_ask "docs edit and delete in the tail" "$(run_guard "$STUB" "$Q_DIR" "$CLEAN_STUB")"

# --- 18. a second artefact added beside one the review saw -----------------
build_pr_repo second app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
  'ALLOWED_ORIGINS = ["https://app.example.com", "https://hr.example.com"]'
Y_DIR="$REPO_DIR" Y_BASE="$REPO_BASE"
git_in "$Y_DIR" checkout -q feature
mkdir -p "$Y_DIR/docs/reviews"
printf '%s\n' '{"findings":[{"id":1,"severity":"HIGH","status":"open"}]}' > "$Y_DIR/docs/reviews/first.json"
git_in "$Y_DIR" add docs
git_in "$Y_DIR" commit -q -m "docs: artefact with an open row"
Y_REVIEWED=$(git -C "$Y_DIR" rev-parse HEAD)
printf '%s\n' '{"findings":[]}' > "$Y_DIR/$ARTEFACT_PATH"
git_in "$Y_DIR" add docs
git_in "$Y_DIR" commit -q -m "docs: a clean second artefact"
Y_HEAD=$(git -C "$Y_DIR" rev-parse HEAD)
git_in "$Y_DIR" push -q origin feature
(cd "$Y_DIR" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1) ||
  report_failure "setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
git_in "$Y_DIR" checkout -q main
Y_BODY=$(pr_body "$(codex_section "$Y_BASE" "$Y_HEAD")" "$(security_section security-reviewer "$EXPECTED_MODEL" "$Y_BASE" "$Y_REVIEWED")")
STUB=$(write_pr_stub second "$Y_BODY" "$Y_HEAD" "$Y_BASE" second)
expect_r109_deny "second artefact beside a reviewed one" \
  "$(run_guard "$STUB" "$Y_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $Y_HEAD")"

# --- 19. a clean artefact in a different directory --------------------------
build_pr_repo elsewhere app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
  'ALLOWED_ORIGINS = ["https://app.example.com", "https://pay.example.com"]'
Z_DIR="$REPO_DIR" Z_BASE="$REPO_BASE"
git_in "$Z_DIR" checkout -q feature
mkdir -p "$Z_DIR/docs/other"
printf '%s\n' '{"findings":[{"id":1,"severity":"HIGH","status":"open"}]}' > "$Z_DIR/docs/other/first.txt"
git_in "$Z_DIR" add docs
git_in "$Z_DIR" commit -q -m "docs: artefact with an open row"
Z_REVIEWED=$(git -C "$Z_DIR" rev-parse HEAD)
mkdir -p "$Z_DIR/docs/reviews"
printf '%s\n' '{"findings":[]}' > "$Z_DIR/$ARTEFACT_PATH"
git_in "$Z_DIR" add docs
git_in "$Z_DIR" commit -q -m "docs: a clean artefact elsewhere"
Z_HEAD=$(git -C "$Z_DIR" rev-parse HEAD)
git_in "$Z_DIR" push -q origin feature
(cd "$Z_DIR" && bash "$RECORD_SCRIPT" "$ARTEFACT_PATH" >/dev/null 2>&1) ||
  report_failure "setup: security-review-record.sh could not record $ARTEFACT_PATH at the PR head"
git_in "$Z_DIR" checkout -q main
Z_BODY=$(pr_body "$(codex_section "$Z_BASE" "$Z_HEAD")" "$(security_section security-reviewer "$EXPECTED_MODEL" "$Z_BASE" "$Z_REVIEWED")")
STUB=$(write_pr_stub elsewhere "$Z_BODY" "$Z_HEAD" "$Z_BASE" elsewhere)
expect_r109_deny "clean artefact in another directory" \
  "$(run_guard "$STUB" "$Z_DIR" "$CLEAN_STUB" "gh pr merge 42 --squash --match-head-commit $Z_HEAD")"

# --- 20. code that arrives only in a merge result, merge diffs off ---------
build_pr_repo evilmerge app/greeting.py 'GREETING = "hello"' 'GREETING = "ahoj"'
K_DIR="$REPO_DIR" K_BASE="$REPO_BASE" K_REVIEWED="$REPO_HEAD"
git_in "$K_DIR" config log.diffMerges off
git_in "$K_DIR" checkout -q -b side "$K_REVIEWED"
mkdir -p "$K_DIR/docs"
printf 'side\n' > "$K_DIR/docs/side.md"
git_in "$K_DIR" add -A
git_in "$K_DIR" commit -q -m "docs: side"
git_in "$K_DIR" checkout -q feature
git_in "$K_DIR" merge -q --no-ff --no-commit side
printf 'EVIL = 1\n' > "$K_DIR/app/evil.py"
git_in "$K_DIR" add -A
git_in "$K_DIR" commit -q -m "merge side"
K_HEAD=$(git -C "$K_DIR" rev-parse HEAD)
git_in "$K_DIR" push -q origin feature
git_in "$K_DIR" checkout -q main
STUB=$(write_pr_stub evilmerge "$(pr_body "$(codex_section "$K_BASE" "$K_REVIEWED")")" "$K_HEAD" "$K_BASE" evilmerge)
expect_r517_deny "code only in a merge result, merge diffs off" "$(run_guard "$STUB" "$K_DIR" "$CLEAN_STUB")"

# --- 21. a replacement object hiding a security change from the detector ----
build_pr_repo hidecors app/middleware/cors_config.py 'ALLOWED_ORIGINS = ["https://app.example.com"]' \
  'ALLOWED_ORIGINS = ["*"]'
H_DIR="$REPO_DIR" H_BASE="$REPO_BASE" H_HEAD="$REPO_HEAD"
DECOY_HEAD=$(git -C "$H_DIR" commit-tree "$H_BASE^{tree}" -p "$H_BASE" -m "decoy" 2>/dev/null)
git_in "$H_DIR" replace "$H_HEAD" "$DECOY_HEAD"
STUB=$(write_pr_stub hidecors "$(pr_body "$(codex_section "$H_BASE" "$H_HEAD")")" "$H_HEAD" "$H_BASE" hidecors)
expect_r109_deny "replacement object hiding a CORS change" "$(run_guard "$STUB" "$H_DIR" "$CLEAN_STUB")"

if [ "$failures" -gt 0 ]; then
  echo "git-workflow-guard-docs-tail.test.sh: $failures failure(s)"
  exit 1
fi
echo "PASS git-workflow-guard-docs-tail.test.sh"
