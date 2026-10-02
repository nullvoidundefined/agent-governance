#!/usr/bin/env bash
# Covers: hook:commit-message-guard
#
# Verifies the R-214 findings ledger (IAN-201) that records work discovered
# while doing something else, and that the commit gate which once refused
# that work inside another task's diff is gone (IAN-568).
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
#  14. A finding with no --value, or a value outside breaking, high, medium,
#      low, none, is refused and leaves the ledger unchanged. The rating is
#      what decides whether the work waits, so an unrated finding is the gap
#      the week of 2026-09-21 fell through (IAN-471).
#  15. A low finding prints Linear priority 3 and a none finding priority 4,
#      each with the instruction not to work it in this session.
#  16. A breaking, high, or medium finding names no fixed priority and no
#      do-not-work instruction, and list shows each finding's value.
#
# Gate removal (IAN-568): commit-message-guard.sh no longer refuses or asks
# about a commit that stages files outside the declared scope. The R-214 norm
# (file what you notice) stays; its commit refusal went because it had no
# recorded catch.
#   6. A commit staging an out-of-scope file with a conventional subject is
#      neither denied nor asked about.
#   7. A `-F <file>` commit and an `--amend --no-edit` staging that file are
#      silent too.
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
OUT=$( (cd "$REPO" && bash "$FINDING" add "the rate limiter drops the first request" --kind bug --value medium --where src/api) 2>&1 )
check "1. add records the finding, got: $OUT" "$(says "$OUT" "finding 1 recorded")"

OUT=$( (cd "$REPO" && bash "$FINDING" add "tidy this later" --kind nice --value low) 2>&1 ); ST=$?
check "2. an unrecognised kind exits non-zero" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"
check "2. the refusal names the three kinds, got: $OUT" "$(says "$OUT" "bug, task, or optimization")"

OUT=$( (cd "$REPO" && bash "$FINDING" add "" --kind task --value low) 2>&1 ); ST=$?
check "3. an empty description is refused" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"

OUT=$( (cd "$REPO" && bash "$FINDING" open) 2>&1 )
check "4. open lists the unticketed finding, got: $OUT" "$(says "$OUT" "NO TICKET")"
OUT=$( (cd "$REPO" && bash "$FINDING" ticket 1 IAN-404) 2>&1 )
check "4. ticket attaches the key, got: $OUT" "$(says "$OUT" "IAN-404")"
OUT=$( (cd "$REPO" && bash "$FINDING" open) 2>&1 )
check "4. open drops a ticketed finding, got: $OUT" "$(says "$OUT" "none recorded")"
OUT=$( (cd "$REPO" && bash "$FINDING" list) 2>&1 )
check "4. list keeps a ticketed finding, got: $OUT" "$(says "$OUT" "IAN-404")"

OUT=$( (cd "$REPO" && bash "$FINDING" add "x" --kind task --value low --ticket not-a-key) 2>&1 ); ST=$?
check "5. a malformed tracker key is refused" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"

# --- value rating (IAN-471) ---
BEFORE=$( (cd "$REPO" && bash "$FINDING" list) 2>&1 )
OUT=$( (cd "$REPO" && bash "$FINDING" add "rename a helper" --kind optimization) 2>&1 ); ST=$?
check "14. a finding with no --value exits non-zero" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"
check "14. the refusal names the five values, got: $OUT" "$(says "$OUT" "breaking, high, medium, low, or none")"
OUT=$( (cd "$REPO" && bash "$FINDING" add "rename a helper" --kind optimization --value meh) 2>&1 ); ST=$?
check "14. a value outside the scale exits non-zero" "$([ "$ST" -ne 0 ] && echo 0 || echo 1)"
AFTER=$( (cd "$REPO" && bash "$FINDING" list) 2>&1 )
check "14. a refused finding leaves the ledger unchanged" "$([ "$BEFORE" = "$AFTER" ] && echo 0 || echo 1)"

OUT=$( (cd "$REPO" && bash "$FINDING" add "reword a hook message" --kind optimization --value low) 2>&1 )
check "15. a low finding files at Linear priority 3, got: $OUT" "$(says "$OUT" "Linear priority 3")"
check "15. a low finding is not worked now, got: $OUT" "$(says "$OUT" "do not work it in this session")"
OUT=$( (cd "$REPO" && bash "$FINDING" add "delete an unused fixture" --kind task --value none) 2>&1 )
check "15. a none finding files at Linear priority 4, got: $OUT" "$(says "$OUT" "Linear priority 4")"
check "15. a none finding is not worked now, got: $OUT" "$(says "$OUT" "do not work it in this session")"
OUT=$( (cd "$REPO" && bash "$FINDING" add "the guard fails open" --kind bug --value high) 2>&1 )
check "16. a high finding gets no do-not-work instruction, got: $OUT" "$([ "$(says "$OUT" "do not work it")" -ne 0 ] && echo 0 || echo 1)"
check "16. a high finding names no fixed priority, got: $OUT" "$([ "$(says "$OUT" "Linear priority")" -ne 0 ] && echo 0 || echo 1)"
check "16. a high finding is still recorded, got: $OUT" "$(says "$OUT" "recorded")"
OUT=$( (cd "$REPO" && bash "$FINDING" list) 2>&1 )
check "16. list shows the low rating, got: $OUT" "$(says "$OUT" "optimization, low: reword a hook message")"
check "16. list shows the none rating, got: $OUT" "$(says "$OUT" "task, none: delete an unused fixture")"

# --- removed gate (IAN-568) ---
jq -n '{tier:"standard",reason:"fixture",branch:"feat/scoped",startedAt:0,startedAtIso:"2026-09-20T00:00:00Z",scope:["src/api/**"],ticket:"IAN-300"}' \
  > "$REPO/.claude/task-tier.json"
run_commit() { jq -n --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | bash "$HOOK"; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }

printf 'drive-by\n' > "$REPO/docs/notes.md"
git -C "$REPO" add docs/notes.md
OUT=$(run_commit 'git commit -m "feat(api): handle the thing"')
check "6. an out-of-scope commit is not refused, got: '$(decision "$OUT")'" "$([ -z "$(decision "$OUT")" ] && echo 0 || echo 1)"

printf 'feat(api): handle the thing\n' > "$TMP/msg.txt"
OUT=$(run_commit "git commit -F $TMP/msg.txt")
check "7. an out-of-scope -F commit is silent, got: '$(decision "$OUT")'" "$([ -z "$(decision "$OUT")" ] && echo 0 || echo 1)"
OUT=$(run_commit 'git commit --amend --no-edit')
check "7. an out-of-scope amend is silent, got: '$(decision "$OUT")'" "$([ -z "$(decision "$OUT")" ] && echo 0 || echo 1)"

[ "$fail" -eq 0 ] || exit 1
echo "finding-ledger.test.sh PASS"
