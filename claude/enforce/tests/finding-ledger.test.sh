#!/usr/bin/env bash
# Covers: hook:commit-message-guard
#
# Verifies R-214's two halves (IAN-201): the findings ledger that records work
# discovered while doing something else, and the commit gate that stops that
# work landing inside another task's diff without a ticket of its own.
#
# The rule exists because a discovery previously had only two fates, and both
# lost it. Fixing it immediately buried unrelated work in the current commit
# under the current task's ticket; mentioning it in chat lost it as soon as
# the conversation moved on, which is why the same defects were rediscovered
# session after session.
#
# Ledger invariants (finding.sh):
#   1. `add` records a finding and reports its id.
#   2. An unrecognised kind is refused, and the refusal names the three kinds.
#   3. A finding with no description is refused.
#   4. `open` lists a finding carrying no ticket; `ticket` attaches a key and
#      `open` then drops it while `list` keeps it.
#   5. A malformed tracker key is refused rather than recorded.
#
# Gate invariants (commit-message-guard.sh, R-214 half):
#   6. A commit staging only in-scope files passes.
#   7. A commit staging an out-of-scope file is denied, and the denial names
#      the file and the rule.
#   8. A second `Refs:` trailer naming another ticket satisfies the gate,
#      because the work is then recorded somewhere the user can find it.
#   9. A `Refs:` naming only the task's own ticket does not satisfy it, since
#      that is the trailer every commit on the branch already carries.
#  10. No declared scope means no constraint, so the gate is silent.
#  12. The gate runs for every commit shape, not only those whose message this
#      hook can parse. `-m` denies; a `-F <file>` commit and an
#      `--amend --no-edit` ask, because the `Refs:` escape cannot be read
#      there. Before the PR #96 review's finding 1 all three but `-m` were a
#      silent allow, so the rule was bypassable by choosing how to commit.
#  13. A ledger declaring a scope but no ticket denies regardless of `Refs:`.
#      With no own key to compare against, any trailer would satisfy the gate,
#      and R-605 already puts a `Refs:` trailer on every commit.
#  11. A staged path under .claude/ never triggers it, because the ledger and
#      the slice lock are session state every task writes. A git-ignored file
#      that was force-staged DOES trigger it: `git add -f` puts it in the
#      index, so it is real content in the commit and a reviewer reads it,
#      which is exactly what the gate is for. The ignore exemption matters
#      for the write gate, where the file is still untracked.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
FINDING="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/finding.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/commit-message-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { [ "$2" -eq 0 ] || { echo "FAIL: $1"; fail=1; }; }
says() { grep -qF -- "$2" <<< "$1" && echo 0 || echo 1; }

REPO="$TMP/repo"
mkdir -p "$REPO/src/api" "$REPO/docs" "$REPO/.claude"
git -C "$REPO" init -q -b feat/scoped
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed.txt"
printf 'build/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "init"

# --- ledger ---
OUT=$( (cd "$REPO" && bash "$FINDING" add "the rate limiter drops the first request" --kind bug --where src/api) 2>&1 )
check "1. add records the finding, got: $OUT" "$(says "$OUT" "finding 1 recorded")"

OUT=$( (cd "$REPO" && bash "$FINDING" add "tidy this later" --kind nice) 2>&1 ); ST=$?
check "2. an unrecognised kind exits non-zero" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"
check "2. the refusal names the three kinds, got: $OUT" "$(says "$OUT" "bug, task, or optimization")"

OUT=$( (cd "$REPO" && bash "$FINDING" add "" --kind task) 2>&1 ); ST=$?
check "3. an empty description is refused" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"

OUT=$( (cd "$REPO" && bash "$FINDING" open) 2>&1 )
check "4. open lists the unticketed finding, got: $OUT" "$(says "$OUT" "NO TICKET")"
OUT=$( (cd "$REPO" && bash "$FINDING" ticket 1 IAN-404) 2>&1 )
check "4. ticket attaches the key, got: $OUT" "$(says "$OUT" "IAN-404")"
OUT=$( (cd "$REPO" && bash "$FINDING" open) 2>&1 )
check "4. open drops a ticketed finding, got: $OUT" "$(says "$OUT" "none recorded")"
OUT=$( (cd "$REPO" && bash "$FINDING" list) 2>&1 )
check "4. list keeps a ticketed finding, got: $OUT" "$(says "$OUT" "IAN-404")"

OUT=$( (cd "$REPO" && bash "$FINDING" add "x" --kind task --ticket not-a-key) 2>&1 ); ST=$?
check "5. a malformed tracker key is refused" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"

# --- gate ---
ledger() { # ledger <scope-json> [ticket]; an explicit empty ticket omits the key
  local ticket="${2-IAN-300}"
  jq -n --argjson s "$1" --arg t "$ticket" \
    '{tier:"standard",reason:"fixture",branch:"feat/scoped",startedAt:0,startedAtIso:"2026-09-20T00:00:00Z",scope:$s}
     + (if $t == "" then {} else {ticket: $t} end)' \
    > "$REPO/.claude/task-tier.json"
}
# The payload carries cwd, as every real PreToolUse payload does. The gate
# resolves the repository from it rather than from the hook process, so a
# fixture is hermetic instead of reading whatever the developer has staged.
run_commit() { jq -n --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | bash "$HOOK"; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }

ledger '["src/api/**"]'
printf 'changed\n' > "$REPO/src/api/handler.ts"
git -C "$REPO" add src/api/handler.ts
OUT=$(run_commit 'git commit -m "feat(api): handle the thing"')
check "6. an in-scope commit passes, got: $(decision "$OUT") $(reason "$OUT")" "$([ "$(decision "$OUT")" != "deny" ] && echo 0 || echo 1)"

printf 'drive-by\n' > "$REPO/docs/notes.md"
git -C "$REPO" add docs/notes.md
OUT=$(run_commit 'git commit -m "feat(api): handle the thing"')
check "7. an out-of-scope commit is denied, got: '$(decision "$OUT")'" "$([ "$(decision "$OUT")" = "deny" ] && echo 0 || echo 1)"
check "7. the denial cites R-214, got: $(reason "$OUT")" "$(says "$(reason "$OUT")" "R-214")"
check "7. the denial names the file, got: $(reason "$OUT")" "$(says "$(reason "$OUT")" "docs/notes.md")"

OUT=$(run_commit 'git commit -m "feat(api): handle the thing" -m "Refs: IAN-300, IAN-777"')
check "8. a second ticket in Refs satisfies the gate, got: $(decision "$OUT") $(reason "$OUT")" "$([ "$(decision "$OUT")" != "deny" ] && echo 0 || echo 1)"

OUT=$(run_commit 'git commit -m "feat(api): handle the thing" -m "Refs: IAN-300"')
check "9. the task's own ticket does not satisfy it, got: '$(decision "$OUT")'" "$([ "$(decision "$OUT")" = "deny" ] && echo 0 || echo 1)"

ledger '[]'
OUT=$(run_commit 'git commit -m "feat(api): handle the thing"')
check "10. no declared scope means no gate, got: $(reason "$OUT")" "$([ "$(decision "$OUT")" != "deny" ] && echo 0 || echo 1)"

ledger '["src/api/**"]'
git -C "$REPO" reset -q
printf 'state\n' > "$REPO/.claude/scratch.json"
git -C "$REPO" add -f .claude/scratch.json src/api/handler.ts
OUT=$(run_commit 'git commit -m "feat(api): handle the thing"')
check "11. a staged .claude path never triggers it, got: $(reason "$OUT")" "$([ "$(decision "$OUT")" != "deny" ] && echo 0 || echo 1)"

mkdir -p "$REPO/build"
printf 'x\n' > "$REPO/build/out.js"
git -C "$REPO" add -f build/out.js
OUT=$(run_commit 'git commit -m "feat(api): handle the thing"')
check "11. a force-staged ignored file is real content and is gated, got: '$(decision "$OUT")'" "$([ "$(decision "$OUT")" = "deny" ] && echo 0 || echo 1)"

# 12. Every commit shape reaches the gate.
ledger '["src/api/**"]'
git -C "$REPO" reset -q
printf 'drive-by\n' > "$REPO/docs/notes.md"
git -C "$REPO" add docs/notes.md
OUT=$(run_commit 'git commit -m "feat(api): handle the thing"')
check "12. -m still denies, got: '$(decision "$OUT")'" "$([ "$(decision "$OUT")" = "deny" ] && echo 0 || echo 1)"

printf 'feat(api): handle the thing\n' > "$TMP/msg.txt"
OUT=$(run_commit "git commit -F $TMP/msg.txt")
check "12. an unreadable -F message asks rather than allowing, got: '$(decision "$OUT")'" "$([ "$(decision "$OUT")" = "ask" ] && echo 0 || echo 1)"
check "12. the ask names the out-of-scope file, got: $(reason "$OUT")" "$(says "$(reason "$OUT")" "docs/notes.md")"

OUT=$(run_commit 'git commit --amend --no-edit')
check "12. an amend reusing its message asks, got: '$(decision "$OUT")'" "$([ "$(decision "$OUT")" = "ask" ] && echo 0 || echo 1)"

# 13. A scope with no ticket cannot be satisfied by any trailer.
ledger '["src/api/**"]' ""
OUT=$(run_commit 'git commit -m "feat(api): handle the thing" -m "Refs: IAN-300"')
check "13. a ledger with no ticket denies despite Refs, got: '$(decision "$OUT")'" "$([ "$(decision "$OUT")" = "deny" ] && echo 0 || echo 1)"

[ "$fail" -eq 0 ] || exit 1
echo "finding-ledger.test.sh PASS"
