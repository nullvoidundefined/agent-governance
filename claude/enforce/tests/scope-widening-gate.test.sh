#!/usr/bin/env bash
# Covers: hook:scope-widening-gate
#
# Verifies scope-widening-gate.sh, the R-212 enforcer: a Write or Edit whose
# target sits outside the file scope the task declared at task-start becomes a
# confirm prompt rather than a silent widening of the diff. Thirteen
# invariants, weighted toward the cases that must stay silent, because a gate
# that asks about ordinary work is worse than no gate at all.
#
#   1. No ledger at all: silent. A session that never ran task-start has
#      declared nothing, and nothing is what an undeclared scope constrains.
#   2. A ledger with no `scope` key: silent, the same degraded path.
#   3. A ledger whose `scope` is the empty array: silent. Declaring no paths
#      is declaring no constraint, never declaring that every path is out.
#   4. A ledger recording another branch: silent, since it belongs to another
#      task, which is how ticket-at-start-gate reads the same field.
#   5. An in-scope Write: silent.
#   6. An out-of-scope Write: asks, and the reason names both the file and the
#      declared scope, so the question can be answered without reading the
#      ledger.
#   7. An out-of-scope Edit: asks. Both tools widen a diff identically.
#   8. A directory named without a wildcard covers the files beneath it.
#   9. A scope entry never matches by substring: `claude/hooks` must not cover
#      `claude/hooks-extra/`, and `docs/a` must not cover `docs/ab.md`.
#  10. A path under the repository's own `.claude/` is exempt, because the
#      ledger and the slice lock are session state that every task writes.
#  11. A git-ignored path is exempt, for the same reason: scratch files and
#      build output are not part of the diff anyone reviews.
#  12. A file outside any git work tree: silent, since there is no ledger to
#      read and no repository-relative path to judge it against.
#  13. A file that does not exist yet is judged by the path it would land at,
#      so creating an out-of-scope file is gated exactly like editing one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/scope-widening-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { # check <description> <0 for pass>
  [ "$2" -eq 0 ] || { echo "FAIL: $1"; fail=1; }
}
silent() { [ -z "$1" ] && echo 0 || echo 1; }
asked() { [ "$(decision "$1")" = "ask" ] && echo 0 || echo 1; }

run() { # run <tool> <cwd> <file-path>
  jq -n --arg t "$1" --arg c "$2" --arg f "$3" \
    '{hook_event_name:"PreToolUse",tool_name:$t,cwd:$c,tool_input:{file_path:$f}}' | bash "$HOOK"
}
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }

new_repo() { # new_repo <name> [branch]
  local repo="$TMP/$1" on_branch="${2:-main}"
  mkdir -p "$repo"
  git -C "$repo" init -q -b "$on_branch" >/dev/null 2>&1
  mkdir -p "$repo/claude/hooks" "$repo/claude/enforce/tests" "$repo/docs" "$repo/.claude"
  printf '%s' "$(cd "$repo" && pwd -P)"
}

write_ledger() { # write_ledger <repo> <branch> <scope-json-or-null>
  jq -n --arg b "$2" --argjson s "$3" \
    '{tier:"standard",reason:"a fixture ledger",branch:$b,startedAt:0,startedAtIso:"2026-09-20T00:00:00Z"}
     + (if $s == null then {} else {scope:$s} end)' > "$1/.claude/task-tier.json"
}

IN_SCOPE='["claude/hooks/**","claude/enforce/tests/**"]'

# 1. No ledger at all.
REPO=$(new_repo one)
OUT=$(run Write "$REPO" "$REPO/docs/anything.md")
check "a repository with no task-start ledger must not be gated, got: $(decision "$OUT")" "$(silent "$OUT")"

# 2. A ledger carrying no scope key.
write_ledger "$REPO" main null
OUT=$(run Write "$REPO" "$REPO/docs/anything.md")
check "a ledger with no scope key must not be gated, got: $(decision "$OUT")" "$(silent "$OUT")"

# 3. An empty scope array.
write_ledger "$REPO" main '[]'
OUT=$(run Write "$REPO" "$REPO/docs/anything.md")
check "an empty scope array declares no constraint and must not be gated, got: $(decision "$OUT")" "$(silent "$OUT")"

# 4. A ledger recording another branch.
write_ledger "$REPO" some-other-branch "$IN_SCOPE"
OUT=$(run Write "$REPO" "$REPO/docs/anything.md")
check "a ledger recording another branch must not be gated, got: $(decision "$OUT")" "$(silent "$OUT")"

# 5. An in-scope Write.
write_ledger "$REPO" main "$IN_SCOPE"
printf 'existing\n' > "$REPO/claude/hooks/existing.sh"
OUT=$(run Write "$REPO" "$REPO/claude/hooks/existing.sh")
check "an in-scope Write must not be gated, got: $(reason "$OUT")" "$(silent "$OUT")"

# 6. An out-of-scope Write asks, naming the file and the declared scope.
printf 'doc\n' > "$REPO/docs/roadmap.md"
OUT=$(run Write "$REPO" "$REPO/docs/roadmap.md")
check "an out-of-scope Write must ask, got: '$(decision "$OUT")'" "$(asked "$OUT")"
check "the ask must cite R-212, got: $(reason "$OUT")" "$(reason "$OUT" | grep -q 'R-212' && echo 0 || echo 1)"
check "the ask must name the file, got: $(reason "$OUT")" "$(reason "$OUT" | grep -q 'docs/roadmap.md' && echo 0 || echo 1)"
check "the ask must name the declared scope, got: $(reason "$OUT")" "$(reason "$OUT" | grep -q 'claude/hooks/\*\*' && echo 0 || echo 1)"

# 7. An out-of-scope Edit asks too.
OUT=$(run Edit "$REPO" "$REPO/docs/roadmap.md")
check "an out-of-scope Edit must ask, got: '$(decision "$OUT")'" "$(asked "$OUT")"

# 8. A directory named without a wildcard covers what is beneath it.
write_ledger "$REPO" main '["claude/hooks"]'
OUT=$(run Write "$REPO" "$REPO/claude/hooks/existing.sh")
check "a bare directory scope entry must cover the files beneath it, got: $(reason "$OUT")" "$(silent "$OUT")"

# 9. Scope entries never match by substring.
mkdir -p "$REPO/claude/hooks-extra"
printf 'x\n' > "$REPO/claude/hooks-extra/other.sh"
OUT=$(run Write "$REPO" "$REPO/claude/hooks-extra/other.sh")
check "a sibling directory sharing a name prefix must not be in scope, got: '$(decision "$OUT")'" "$(asked "$OUT")"
write_ledger "$REPO" main '["docs/a"]'
printf 'x\n' > "$REPO/docs/ab.md"
OUT=$(run Write "$REPO" "$REPO/docs/ab.md")
check "a file sharing a name prefix with a scope entry must not be in scope, got: '$(decision "$OUT")'" "$(asked "$OUT")"

# 10. The repository's own .claude/ is exempt.
write_ledger "$REPO" main "$IN_SCOPE"
OUT=$(run Write "$REPO" "$REPO/.claude/task-tier.json")
check "the repository's own .claude/ must be exempt, got: $(reason "$OUT")" "$(silent "$OUT")"

# 11. A git-ignored path is exempt.
printf 'scratch/\n' > "$REPO/.gitignore"
mkdir -p "$REPO/scratch"
printf 'x\n' > "$REPO/scratch/notes.txt"
OUT=$(run Write "$REPO" "$REPO/scratch/notes.txt")
check "a git-ignored path must be exempt, got: $(reason "$OUT")" "$(silent "$OUT")"

# 12. Outside any git work tree.
mkdir -p "$TMP/loose"
printf 'x\n' > "$TMP/loose/file.txt"
OUT=$(run Write "$TMP/loose" "$TMP/loose/file.txt")
check "a path outside any git work tree must not be gated, got: $(decision "$OUT")" "$(silent "$OUT")"

# 13. A file that does not exist yet is judged by where it would land.
OUT=$(run Write "$REPO" "$REPO/docs/new/deeper/unwritten.md")
check "a file that does not exist yet must be judged by its path, got: '$(decision "$OUT")'" "$(asked "$OUT")"
OUT=$(run Write "$REPO" "$REPO/claude/hooks/new/unwritten.sh")
check "an in-scope file that does not exist yet must not be gated, got: $(reason "$OUT")" "$(silent "$OUT")"

[ "$fail" -eq 0 ] || exit 1
echo "scope-widening-gate.test.sh PASS"
