#!/usr/bin/env bash
# Shard: slow
# Covers: hook:draft-pr-on-first-push
# Verifies hooks/draft-pr-on-first-push.sh (R-517): after a successful Bash
# `git push` of a non-default branch with no open pull request, the hook
# opens a draft with `gh pr create --draft` (title from the oldest commit,
# body listing the subjects, the distinct Refs lines, and the attribution
# line) and hands the session the PR monitor instruction. It opens nothing
# for an existing PR, a push of main, a failed push, a dry run, a delete, a
# tag-only push, a quoted "git push", or an `autoDraftPr: false` opt-out, and
# with no Refs line outside the docs-only and trivial exemptions it opens
# nothing and names /ticket-lifecycle. gh is a stub on PATH that records its
# calls; git is real, pushing to a local bare repository, so nothing reaches
# GitHub. Every repository and every HOME is a sandbox.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/draft-pr-on-first-push.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CLAUDE_ENFORCE_BASE CLAUDE_GH_CMD
export CLAUDE_FIRE_LOG=/dev/null CLAUDE_GH_TIMEOUT_SECONDS=5

fail=0
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
OUT=""
TRACKED_HOME="$SB/home"
UNTRACKED_HOME="$SB/home-without-tracker"
mkdir -p "$TRACKED_HOME/.claude" "$UNTRACKED_HOME/.claude" "$SB/bin"
printf '{"tracker":"linear"}\n' > "$TRACKED_HOME/.claude/TICKET-TRACKER.json"
GH_LOG="$SB/gh-calls.log"
GH_BODY="$SB/gh-body.md"

# The gh stub: `pr list` prints $GH_STUB_PRS as the JSON list of the
# branch's PRs in every state (an open PR at $GH_STUB_EXISTING_URL when that
# is set, else none), `pr create` copies its --body-file to $GH_BODY and prints a PR URL,
# and $GH_STUB_FAIL set makes every call exit 1. Each call is logged.
cat > "$SB/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ -n "${GH_STUB_FAIL:-}" ] && { echo "gh: authentication required" >&2; exit 1; }
case "$1 $2" in
  "pr list")
    if [ -n "${GH_STUB_PRS:-}" ]; then printf '%s\n' "$GH_STUB_PRS"
    elif [ -n "${GH_STUB_EXISTING_URL:-}" ]; then printf '[{"number":3,"state":"OPEN","url":"%s"}]\n' "$GH_STUB_EXISTING_URL"
    else echo '[]'; fi ;;
  "pr create")
    previous=""
    for arg in "$@"; do [ "$previous" = "--body-file" ] && cp "$arg" "$GH_BODY"; previous="$arg"; done
    echo "https://github.com/example/app/pull/7" ;;
  "repo view") echo "main" ;;
esac
exit 0
STUB
chmod +x "$SB/bin/gh"
export GH_LOG GH_BODY
STUB_PATH="$SB/bin:$PATH"

# check <name> <command...>: records one PASS or FAIL line for an assertion.
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }
not() { ! "$@"; }

# was_draft_opened: true when the stub saw a `pr create --draft` call.
was_draft_opened() { [ -f "$GH_LOG" ] && grep -q -- '^pr create --draft' "$GH_LOG"; }
# is_silent: true when the hook emitted nothing.
is_silent() { [ -z "$OUT" ]; }
# output_has <text>: true when the context contains the text.
output_has() { jq -r '.hookSpecificOutput.additionalContext // ""' <<< "$OUT" | grep -qF -- "$1"; }
# body_has <text>: true when the draft body the stub received contains it.
body_has() { grep -qF -- "$1" "$GH_BODY"; }
# gh_logged <text>: true when some gh call carried the text.
gh_logged() { grep -qF -- "$1" "$GH_LOG"; }

# make_repo <name> <path> <message>...: a repository with a bare origin whose
# default branch is main, checked out on feat/x with one commit per message,
# each adding <path> content; prints its path.
make_repo() {
  local dir="$SB/$1" origin="$SB/$1-origin.git" path="$2" message index=0; shift 2
  git init -q --bare -b main "$origin"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  printf '# app\n' > "$dir/README.md"; git -C "$dir" add -A; git -C "$dir" commit -qm init
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push -q origin main 2>/dev/null
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$dir" switch -q -c feat/x
  for message in "$@"; do
    index=$((index + 1))
    mkdir -p "$dir/$(dirname "$path")"; printf '%s\n' "$index" >> "$dir/$path"
    git -C "$dir" add -A; git -C "$dir" commit -qm "$message"
  done
  printf '%s' "$dir"
}

# push_branch <repo> [ref]: really pushes the branch so the tracking ref exists.
push_branch() { git -C "$1" push -q -u origin "${2:-feat/x}" 2>/dev/null; }

# run_hook <repo> <command> [home] [stderr] [interrupted]: feeds the hook one
# PostToolUse Bash payload from inside the repository; sets OUT.
run_hook() {
  local payload
  payload=$(jq -nc --arg c "$2" --arg d "$1" --arg e "${4:-}" --argjson i "${5:-false}" \
    '{tool_name:"Bash",cwd:$d,tool_input:{command:$c},tool_response:{stdout:"",stderr:$e,interrupted:$i}}')
  rm -f "$GH_LOG" "$GH_BODY"
  OUT=$(cd "$1" && printf '%s' "$payload" | HOME="${3:-$TRACKED_HOME}" PATH="$STUB_PATH" bash "$HOOK" 2>/dev/null)
}

REFS_ONE=$(printf 'feat: add the service\n\nBody.\n\nRefs: IAN-137\nCo-Authored-By: X <x@example.invalid>')
REFS_TWO=$(printf 'feat: wire the route\n\nRefs: IAN-137')

# First push with Refs: a draft opens against main with the expected title
# and body, and the context carries the monitor instruction.
R=$(make_repo first src/service.ts "$REFS_ONE" "$REFS_TWO")
push_branch "$R"
run_hook "$R" "git push -u origin feat/x"
check "first push with Refs opens a draft" was_draft_opened
check "draft targets the default branch" gh_logged "--base main --head feat/x"
check "title is the oldest commit subject" gh_logged "--title feat: add the service"
check "body lists the commit subjects" body_has "- feat: wire the route"
check "body carries the Refs line" body_has "Refs: IAN-137"
check "body carries the Refs line once" test "$(grep -c 'Refs: IAN-137' "$GH_BODY")" -eq 1
check "body ends with the attribution line" test "$(tail -1 "$GH_BODY")" = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'
check "context names the draft URL" output_has "https://github.com/example/app/pull/7"
check "context carries the monitor instruction" output_has "mcp__ccd_pr__set_monitor"
check "context forbids unasked auto-merge" output_has "Never call mcp__ccd_pr__set_auto_merge"

# A cd prefix and the default refspec form still count.
run_hook "$SB" "cd $R && git push"
check "cd-prefixed bare git push opens a draft" was_draft_opened

# Redirections are not push arguments, and @ is HEAD.
run_hook "$R" "git push 2>&1 | tail -3"
check "push with 2>&1 piped opens a draft" was_draft_opened
run_hook "$R" "git push origin feat/x >/dev/null 2>&1"
check "push with redirections opens a draft" was_draft_opened
run_hook "$R" "git push origin @"
check "push of @ opens a draft" was_draft_opened

# --repo in its space form names the remote the push went to.
git -C "$R" remote add mirror "$SB/first-origin.git"
run_hook "$R" "git push --repo mirror"
check "--repo naming an unfetched remote opens nothing" not was_draft_opened
git -C "$R" fetch -q mirror
run_hook "$R" "git push --repo mirror"
check "--repo naming a fetched remote opens a draft" was_draft_opened
git -C "$R" remote remove mirror

# An open PR already exists: nothing is created.
GH_STUB_EXISTING_URL="https://github.com/example/app/pull/3" run_hook "$R" "git push"
check "existing PR opens nothing" not was_draft_opened
check "existing PR is silent" is_silent

# A branch that ever had a PR: a merged or closed one opens nothing and
# names the earlier PR; reusing the branch name needs a deliberate create.
GH_STUB_PRS='[{"number":5,"state":"MERGED","url":"https://github.com/example/app/pull/5"}]' run_hook "$R" "git push"
check "merged PR on the branch opens nothing" not was_draft_opened
check "merged PR note names the number and state" output_has "#5 (MERGED)"
check "merged PR note names the URL" output_has "https://github.com/example/app/pull/5"
check "merged PR note names the deliberate create" output_has "deliberate \`gh pr create\`"
check "merged PR asks all states" gh_logged "--state all"
GH_STUB_PRS='[{"number":6,"state":"CLOSED","url":"https://github.com/example/app/pull/6"}]' run_hook "$R" "git push"
check "closed PR on the branch opens nothing" not was_draft_opened
check "closed PR note names the number and state" output_has "#6 (CLOSED)"
check "closed PR note is one line" test "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$OUT" | wc -l | tr -d ' ')" -le 1
GH_STUB_PRS='[{"number":6,"state":"CLOSED","url":"https://github.com/example/app/pull/6"},{"number":8,"state":"OPEN","url":"https://github.com/example/app/pull/8"}]' run_hook "$R" "git push"
check "an open PR beside a closed one opens nothing" not was_draft_opened
check "an open PR beside a closed one is silent" is_silent

# A push of main opens nothing and never calls gh.
git -C "$R" switch -q main
run_hook "$R" "git push origin main"
check "push of main opens nothing" not was_draft_opened
check "push of main never calls gh" test ! -f "$GH_LOG"
git -C "$R" switch -q feat/x

# A failed push: rejected on stderr, interrupted, or the tracking ref behind HEAD.
run_hook "$R" "git push" "" "error: failed to push some refs"
check "rejected push opens nothing" not was_draft_opened
run_hook "$R" "git push" "" "" true
check "interrupted push opens nothing" not was_draft_opened
printf 'more\n' >> "$R/src/service.ts"; git -C "$R" commit -qam "$REFS_TWO"
run_hook "$R" "git push"
check "push whose tracking ref lags HEAD opens nothing" not was_draft_opened
push_branch "$R"

# Not a push of the branch: dry run, delete, tag-only.
run_hook "$R" "git push --dry-run origin feat/x"
check "--dry-run opens nothing" not was_draft_opened
run_hook "$R" "git push -n"
check "-n opens nothing" not was_draft_opened
run_hook "$R" "git push origin --delete feat/old"
check "--delete opens nothing" not was_draft_opened
git -C "$R" tag v1
run_hook "$R" "git push origin v1"
check "tag-only refspec opens nothing" not was_draft_opened
run_hook "$R" "git push --tags"
check "--tags opens nothing" not was_draft_opened

# A quoted "git push" inside another command is not a push.
run_hook "$R" "git commit -m 'then git push the branch'"
check "quoted git push in a commit message opens nothing" not was_draft_opened
run_hook "$R" 'echo "git push origin feat/x"'
check "quoted git push in an echo opens nothing" not was_draft_opened

# The opt-out.
printf '{"autoDraftPr": false}\n' > "$R/.enforce.json"
run_hook "$R" "git push"
check "autoDraftPr false opts out" not was_draft_opened
check "opt-out is silent" is_silent
rm -f "$R/.enforce.json"

# No Refs and not exempt: nothing opens and the note names the fix.
R=$(make_repo noref src/service.ts "feat: add the service")
push_branch "$R"
run_hook "$R" "git push -u origin feat/x"
check "no Refs opens nothing" not was_draft_opened
check "no Refs note names /ticket-lifecycle" output_has "/ticket-lifecycle"
check "no Refs note names the trailer" output_has "Refs: <KEY>"

# No Refs with no tracker: the degraded path opens the draft and says so.
run_hook "$R" "git push" "$UNTRACKED_HOME"
check "no tracker opens the draft on the degraded path" was_draft_opened
check "degraded context names TICKET-TRACKER.json" output_has "TICKET-TRACKER.json"

# A trivial tier recorded for the branch is exempt.
mkdir -p "$R/.claude"
printf '{"tier":"trivial","reason":"one line","branch":"feat/x"}\n' > "$R/.claude/task-tier.json"
run_hook "$R" "git push"
check "trivial tier opens a draft without Refs" was_draft_opened

# A docs-only range without Refs opens a draft.
R=$(make_repo docs docs/guide.md "docs: explain the service")
push_branch "$R"
run_hook "$R" "git push -u origin feat/x"
check "docs-only range without Refs opens a draft" was_draft_opened
check "docs-only body has no Refs line" not body_has "Refs:"

# gh failing: the push is untouched and the hook says so in one line.
GH_STUB_FAIL=1 run_hook "$R" "git push"
check "gh failure opens nothing" not was_draft_opened
check "gh failure leaves a one-line note" output_has "no draft pull request was opened"
check "gh failure note is one line" test "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$OUT" | wc -l | tr -d ' ')" -le 1

# A malformed timeout falls back to the default rather than erroring.
CLAUDE_GH_TIMEOUT_SECONDS=abc run_hook "$R" "git push"
check "malformed timeout still opens the draft" was_draft_opened

# No gh on PATH at all: exit 0 with a note, never an error.
OUT=$(cd "$R" && jq -nc --arg c "git push" '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:"",stderr:"",interrupted:false}}' \
  | HOME="$TRACKED_HOME" CLAUDE_GH_CMD=no-such-gh-binary bash "$HOOK" 2>/dev/null); status=$?
check "missing gh exits 0" test "$status" -eq 0
check "missing gh names the cause" output_has "gh CLI is not installed"

# A non-push command costs nothing and says nothing.
run_hook "$R" "ls -la"
check "unrelated command is silent" is_silent

if [ "$fail" -eq 0 ]; then echo "draft-pr-on-first-push.test.sh PASS"; else echo "draft-pr-on-first-push.test.sh FAIL"; fi
exit "$fail"
