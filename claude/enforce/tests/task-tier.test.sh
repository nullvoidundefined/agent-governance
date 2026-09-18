#!/usr/bin/env bash
# task-tier.test.sh: verifies skills/task-start/scripts/task-tier.sh (2026-09-17
# skills audit, S-8): set writes the ledger with tier, reason, branch, and the
# R-503 start timestamp; an invalid tier is refused; get and summary read it
# back; a second set records the reclassification; clear removes it; the
# gitignore note fires only when the project does not ignore the ledger.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TIER="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF "$1" <<< "$OUT"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b feat/presets
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"

OUT=$(cd "$REPO" && bash "$TIER" get 2>&1); ST=$?
check "get with no ledger exits 1" test "$ST" -eq 1
check "get with no ledger says so" reports "no tier recorded"

OUT=$(cd "$REPO" && bash "$TIER" set gigantic "too big" 2>&1); ST=$?
check "invalid tier refused" test "$ST" -eq 1
check "invalid tier named" reports "gigantic"
check "invalid tier writes nothing" test ! -e "$REPO/.claude/task-tier.json"

# The investigation tier (2026-09-18 external audit): a task whose deliverable
# is an answer rather than a change is classified by what it produces, so the
# ledger has to accept it the way it accepts the four size tiers.
OUT=$(cd "$REPO" && bash "$TIER" set investigation "audit the enforcement surface" 2>&1); ST=$?
check "investigation tier accepted" test "$ST" -eq 0
check "investigation tier announced" reports "task-tier: investigation: audit the enforcement surface"
investigationTierRecorded() {
  jq -e '.tier == "investigation"' "$REPO/.claude/task-tier.json" >/dev/null
}
check "investigation tier recorded in the ledger" investigationTierRecorded
rm -f "$REPO/.claude/task-tier.json"

OUT=$(cd "$REPO" && bash "$TIER" set standard "multi-file change with tests" --share 40 2>&1); ST=$?
check "set exits 0" test "$ST" -eq 0
check "set announces the tier" reports "task-tier: standard: multi-file change with tests"
check "gitignore note when not ignored" reports "not gitignored"
check "ledger written" test -f "$REPO/.claude/task-tier.json"
check "ledger carries the tier" test "$(jq -r .tier "$REPO/.claude/task-tier.json")" = "standard"
check "ledger carries the branch" test "$(jq -r .branch "$REPO/.claude/task-tier.json")" = "feat/presets"
check "ledger carries the share" test "$(jq -r .sharePercent "$REPO/.claude/task-tier.json")" = "40"
check "ledger carries an epoch start" test "$(jq -r .startedAt "$REPO/.claude/task-tier.json")" -gt 1700000000

printf '.claude/task-tier.json\n' > "$REPO/.gitignore"
OUT=$(cd "$REPO" && bash "$TIER" set complex "touches auth across three packages" 2>&1)
check "no gitignore note once ignored" bash -c "! printf '%s' \"\$0\" | grep -q 'not gitignored'" "$OUT"
check "reclassification announced" reports "reclassified standard -> complex"
check "ledger records the previous tier" test "$(jq -r .reclassifiedFrom "$REPO/.claude/task-tier.json")" = "standard"

OUT=$(cd "$REPO" && bash "$TIER" get 2>&1)
check "get prints json" bash -c "printf '%s' \"\$0\" | jq -e '.tier == \"complex\"' >/dev/null" "$OUT"
OUT=$(cd "$REPO" && bash "$TIER" summary 2>&1)
check "summary names tier, reason, branch" bash -c "printf '%s' \"\$0\" | grep -q 'complex | touches auth across three packages | started .* elapsed | branch feat/presets'" "$OUT"

OUT=$(cd "$REPO" && bash "$TIER" clear 2>&1)
check "clear removes the ledger" test ! -e "$REPO/.claude/task-tier.json"
OUT=$(cd "$REPO" && bash "$TIER" clear 2>&1); ST=$?
check "clear is idempotent" test "$ST" -eq 0

OUT=$(cd "$SB" && bash "$TIER" get 2>&1); ST=$?
check "outside a repo refused" test "$ST" -eq 1

[ "$fail" -eq 0 ] && echo "task-tier.test.sh PASS"
exit "$fail"
