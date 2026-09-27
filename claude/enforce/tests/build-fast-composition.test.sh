#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# build-fast-composition.test.sh: pins that build-fast's ledger fields change
# nothing a blocking gate decides (IAN-401, spec criterion 8). With
# `lane: fast` and `mergeMode: green` on the task-tier ledger, the merge guard
# still asks for the R-514 confirmation on `gh pr merge`, and the test-author
# guard decides a test-file write exactly as it does without them; with no
# ledger at all, a reminder-only hook still reminds, so a build that never
# opted into build-fast is unchanged.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
MERGE_GUARD="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
TEST_AUTHOR_GUARD="$CLAUDE_HARNESS_ROOT/hooks/codex-test-author-guard.sh"
REMINDER="$CLAUDE_HARNESS_ROOT/hooks/clean-code-reminder.sh"
TIER="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CLAUDE_HOOK_RUNTIME

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }

SB=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$SB"' EXIT
TRACKERLESS_HOME="$SB/home"; mkdir -p "$TRACKERLESS_HOME"

# A Semgrep stand-in reporting a complete clean scan (as git-workflow-guard.test.sh uses).
CLEAN_SEMGREP="$SB/clean-semgrep"
cat >"$CLEAN_SEMGREP" <<'STUB'
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
chmod +x "$CLEAN_SEMGREP"
export CLAUDE_SEMGREP_CMD="$CLEAN_SEMGREP"

# A docs-only PR range: main holds a base commit, docs/notes adds one prose file,
# and refs/remotes/origin/main points at the base.
REPO="$SB/repo"
git -C "$SB" init -q -b main repo
git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name T
printf '# Fixture\n' >"$REPO/README.md"; printf '.claude/\n' >"$REPO/.gitignore"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "chore: seed"
git -C "$REPO" checkout -q -b docs/notes
mkdir -p "$REPO/docs"; printf '# Notes\n\nPlain prose.\n' >"$REPO/docs/notes.md"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "docs: add notes"
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse main)"
HEAD_OID=$(git -C "$REPO" rev-parse HEAD)

# A gh stand-in answering `gh pr view` with a PR whose Codex review section is
# valid for its head, so the merge guard reaches its final R-514 ask.
GH_STUB="$SB/gh-stub"
BODY='## Summary\nWork.\n\n## Codex review\n- reviewer: pr-reviewer\n- model: fable\n- range: '"${HEAD_OID:0:7}"'..'"${HEAD_OID:0:7}"'\n- No findings.'
printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\n' \
  '{"body":"'"$BODY"'","labels":[],"commits":[],"headRefName":"docs/notes","isCrossRepository":false,"url":"https://github.com/o/r/pull/42","baseRefName":"main","headRefOid":"'"$HEAD_OID"'"}' >"$GH_STUB"
chmod +x "$GH_STUB"

# setLedger <lane-args...>: records a standard tier for the checked-out branch,
# with any build-fast flags passed, under a HOME with no ticket tracker.
setLedger() {
  rm -f "$REPO/.claude/task-tier.json"
  (cd "$REPO" && HOME="$TRACKERLESS_HOME" bash "$TIER" set standard "fixture reason" "$@" >/dev/null 2>&1)
}

# assertLedgerFastGreen <label>: the last setLedger really wrote lane fast and
# merge mode green, so the unchanged decisions below are not a ledger that
# silently failed to record the build-fast fields.
assertLedgerFastGreen() {
  local ledger="$REPO/.claude/task-tier.json"
  check "$1: ledger records lane fast" test "$(jq -r '.lane' "$ledger" 2>/dev/null)" = "fast"
  check "$1: ledger records merge mode green" test "$(jq -r '.mergeMode' "$ledger" 2>/dev/null)" = "green"
}

# mergeGuardOutput: the merge guard's full output for `gh pr merge 42 --squash`.
mergeGuardOutput() {
  jq -nc --arg c 'gh pr merge 42 --squash' --arg d "$REPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | HOME="$TRACKERLESS_HOME" CLAUDE_GH_CMD="$GH_STUB" "$MERGE_GUARD" 2>/dev/null
}

# testAuthorGuardOutput: the test-author guard's output for a Write to a test file.
testAuthorGuardOutput() {
  mkdir -p "$REPO/tests"
  jq -nc --arg f "$REPO/tests/notes.test.ts" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' \
    | HOME="$TRACKERLESS_HOME" "$TEST_AUTHOR_GUARD" 2>/dev/null
}

# Case 1: the merge guard's R-514 ask is the same with and without build-fast fields.
setLedger
withoutLane=$(mergeGuardOutput)
setLedger --lane fast --merge-mode green
assertLedgerFastGreen "merge guard case"
withLane=$(mergeGuardOutput)
check "merge guard asks without a lane" grep -qF "R-514: merging a PR needs explicit user authorization" <<< "$withoutLane"
check "merge guard still asks with lane fast and merge mode green" grep -qF "R-514: merging a PR needs explicit user authorization" <<< "$withLane"
check "merge guard decision unchanged by build-fast fields" test "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$withLane")" = "ask"

# Case 2: the test-author guard decides identically with and without build-fast fields.
setLedger
withoutLane=$(testAuthorGuardOutput)
setLedger --lane fast --merge-mode green
assertLedgerFastGreen "test-author guard case"
withLane=$(testAuthorGuardOutput)
check "test-author guard output unchanged by build-fast fields" test "$withoutLane" = "$withLane"

# Case 3: with no ledger at all, a reminder-only hook still reminds.
rm -f "$REPO/.claude/task-tier.json"
mkdir -p "$REPO/src"
{
  printf 'export function oversizedComputation(): number {\n    let total = 0;\n'
  for i in $(seq 1 30); do printf '    total += %s;\n' "$i"; done
  printf '    return total;\n}\n'
} >"$REPO/src/long.ts"
reminder=$(jq -n --arg f "$REPO/src/long.ts" '{tool_input:{file_path:$f}}' | "$REMINDER")
check "reminder fires for a non-opt-in build" grep -qF "R-322" <<< "$reminder"

[ "$fail" -eq 0 ] || exit 1
echo "build-fast-composition.test.sh PASS"
