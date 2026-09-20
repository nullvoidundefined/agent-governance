#!/usr/bin/env bash
# task-tier.test.sh: verifies skills/task-start/scripts/task-tier.sh (2026-09-17
# skills audit, S-8): set writes the ledger with tier, reason, branch, and the
# R-503 start timestamp; an invalid tier is refused; get and summary read it
# back; a second set records the reclassification; clear removes it; the
# gitignore note fires only when the project does not ignore the ledger.
# IAN-149 (R-605 at task start): --ticket <KEY> records the tracker ticket; with
# the tracker configured a non-trivial tier needs one (a same-branch ledger's
# ticket carries over on reclassification); a malformed key is refused; the
# summary names the ticket. HOME is always a sandbox: the cases above the
# IAN-149 block run with the tracker NOT configured.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TIER="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF -- "$1" <<< "$OUT"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
TRACKED_HOME="$SB/home"
UNTRACKED_HOME="$SB/home-without-tracker"
mkdir -p "$TRACKED_HOME/.claude" "$UNTRACKED_HOME/.claude"
printf '{}\n' > "$TRACKED_HOME/.claude/TICKET-TRACKER.json"
export HOME="$UNTRACKED_HOME"
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
check "no gitignore note once ignored" bash -c "! grep -q 'not gitignored' <<< \"\$0\"" "$OUT"
check "reclassification announced" reports "reclassified standard -> complex"
check "ledger records the previous tier" test "$(jq -r .reclassifiedFrom "$REPO/.claude/task-tier.json")" = "standard"

OUT=$(cd "$REPO" && bash "$TIER" get 2>&1)
check "get prints json" bash -c "printf '%s' \"\$0\" | jq -e '.tier == \"complex\"' >/dev/null" "$OUT"
OUT=$(cd "$REPO" && bash "$TIER" summary 2>&1)
check "summary names tier, reason, branch" bash -c "grep -q 'complex | touches auth across three packages | started .* elapsed | branch feat/presets' <<< \"\$0\"" "$OUT"

OUT=$(cd "$REPO" && bash "$TIER" clear 2>&1)
check "clear removes the ledger" test ! -e "$REPO/.claude/task-tier.json"
OUT=$(cd "$REPO" && bash "$TIER" clear 2>&1); ST=$?
check "clear is idempotent" test "$ST" -eq 0

OUT=$(cd "$SB" && bash "$TIER" get 2>&1); ST=$?
check "outside a repo refused" test "$ST" -eq 1

# --- IAN-149: the ticket key on the ledger -----------------------------------
T="$SB/tickets"; mkdir -p "$T"
git -C "$T" init -q -b feat/tickets
git -C "$T" config user.email t@example.invalid; git -C "$T" config user.name t
printf 'a\n' > "$T/a.txt"; printf '.claude/task-tier.json\n' > "$T/.gitignore"
git -C "$T" add -A; git -C "$T" commit -qm "init"
TLEDGER="$T/.claude/task-tier.json"
# field <jq filter>: prints one field of the IAN-149 sandbox ledger.
field() { jq -r "$1" "$TLEDGER"; }
# tier_set <home> <args...>: runs task-tier.sh set in the sandbox repo; sets OUT and ST.
tier_set() { local home="$1"; shift; OUT=$(cd "$T" && HOME="$home" bash "$TIER" set "$@" 2>&1); ST=$?; }
# ledger_unchanged: true when the ledger still matches the snapshot taken before the call.
ledger_unchanged() { cmp -s "$TLEDGER" "$SB/ledger-before.json"; }

# T-1: --ticket is recorded, alone and alongside --share in either order.
tier_set "$TRACKED_HOME" standard "multi-file change" --ticket IAN-7
check "T-1 set with --ticket exits 0" test "$ST" -eq 0
check "T-1 ledger carries the ticket" test "$(field .ticket)" = "IAN-7"
tier_set "$TRACKED_HOME" standard "multi-file change" --ticket IAN-8 --share 30
check "T-1 --ticket then --share exits 0" test "$ST" -eq 0
check "T-1 --ticket then --share records the ticket" test "$(field .ticket)" = "IAN-8"
check "T-1 --ticket then --share records the share" test "$(field .sharePercent)" = "30"
tier_set "$TRACKED_HOME" standard "multi-file change" --share 25 --ticket IAN-9
check "T-1 --share then --ticket exits 0" test "$ST" -eq 0
check "T-1 --share then --ticket records the ticket" test "$(field .ticket)" = "IAN-9"
check "T-1 --share then --ticket records the share" test "$(field .sharePercent)" = "25"

# T-2: tracker configured, non-trivial tier, no --ticket, no ledger: refused, nothing written.
for tier in standard complex saga investigation; do
  rm -f "$TLEDGER"
  tier_set "$TRACKED_HOME" "$tier" "needs a ticket"
  check "T-2 $tier without --ticket exits 1" test "$ST" -eq 1
  check "T-2 $tier refusal names --ticket" reports "--ticket"
  check "T-2 $tier refusal writes no ledger" test ! -e "$TLEDGER"
done

# T-3: tracker configured, trivial tier needs no ticket.
rm -f "$TLEDGER"
tier_set "$TRACKED_HOME" trivial "one-line typo"
check "T-3 trivial without --ticket exits 0" test "$ST" -eq 0
check "T-3 trivial recorded" test "$(field .tier)" = "trivial"

# T-2: an existing ledger without a ticket is left byte-for-byte unchanged by the refusal.
cp "$TLEDGER" "$SB/ledger-before.json"
tier_set "$TRACKED_HOME" complex "grew past trivial"
check "T-2 reclassify from an unticketed ledger without --ticket exits 1" test "$ST" -eq 1
check "T-2 refusal names --ticket" reports "--ticket"
check "T-2 refusal leaves the existing ledger unchanged" ledger_unchanged

# T-4: tracker NOT configured, non-trivial tier without --ticket succeeds (degraded path).
rm -f "$TLEDGER"
tier_set "$UNTRACKED_HOME" complex "no tracker on this machine"
check "T-4 untracked non-trivial without --ticket exits 0" test "$ST" -eq 0
check "T-4 untracked non-trivial recorded" test "$(field .tier)" = "complex"

# T-5: a value that is not a ticket key is refused and writes nothing.
tier_set "$TRACKED_HOME" standard "baseline" --ticket IAN-10
cp "$TLEDGER" "$SB/ledger-before.json"
for bad in "ian-7" "R-605x" ""; do
  tier_set "$TRACKED_HOME" complex "bad key" --ticket "$bad"
  check "T-5 --ticket '$bad' exits 1" test "$ST" -eq 1
  check "T-5 --ticket '$bad' leaves the ledger unchanged" ledger_unchanged
done
rm -f "$TLEDGER"
tier_set "$TRACKED_HOME" standard "bad key, no ledger" --ticket "ian-7"
check "T-5 bad key with no ledger exits 1" test "$ST" -eq 1
check "T-5 bad key with no ledger writes nothing" test ! -e "$TLEDGER"

# T-6: reclassifying on the same branch keeps the ledger's ticket and satisfies T-2.
tier_set "$TRACKED_HOME" standard "first read" --ticket IAN-11
tier_set "$TRACKED_HOME" complex "bigger than it looked"
check "T-6 same-branch reclassify without --ticket exits 0" test "$ST" -eq 0
check "T-6 reclassify keeps the ticket" test "$(field .ticket)" = "IAN-11"
check "T-6 reclassify records the new tier" test "$(field .tier)" = "complex"
check "T-6 reclassify records the previous tier" test "$(field .reclassifiedFrom)" = "standard"

# T-7: summary names the ticket.
OUT=$(cd "$T" && HOME="$TRACKED_HOME" bash "$TIER" summary 2>&1)
check "T-7 summary names the ticket" reports "IAN-11"

# T-6 boundary: a ticket recorded for another branch does not carry over.
git -C "$T" switch -q -c feat/other
tier_set "$TRACKED_HOME" complex "new task on another branch"
check "T-6 other-branch ledger ticket does not carry over (exits 1)" test "$ST" -eq 1
check "T-6 other-branch refusal names --ticket" reports "--ticket"

# S-1 (IAN-193, R-212): --scope records the declared file scope that
# hooks/scope-widening-gate.sh reads, every entry of it. The first version
# split the comma-separated list with `printf '%s'`, which emits no trailing
# newline, so `while read` silently dropped the last entry and the gate then
# asked about a file the task had legitimately declared.
S1="$SB/scope"; mkdir -p "$S1"
git -C "$S1" init -q -b feat/scope
git -C "$S1" config user.email t@example.invalid; git -C "$S1" config user.name t
printf 'a\n' > "$S1/a.txt"; git -C "$S1" add -A; git -C "$S1" commit -qm "init"
scope_of() { jq -c '.scope // []' "$S1/.claude/task-tier.json" 2>/dev/null; }

OUT=$(cd "$S1" && bash "$TIER" set standard "r" --scope "src/services/**,src/api/**,docs/notes.md" 2>&1); ST=$?
check "S-1 --scope exits 0" test "$ST" -eq 0
check "S-1 --scope keeps every entry, including the last" test "$(scope_of)" = '["src/services/**","src/api/**","docs/notes.md"]'

OUT=$(cd "$S1" && bash "$TIER" set complex "grew" 2>&1)
check "S-1 a reclassification on the same branch keeps the scope" test "$(scope_of)" = '["src/services/**","src/api/**","docs/notes.md"]'

OUT=$(cd "$S1" && bash "$TIER" set standard "r" --scope "src/one/**" 2>&1)
check "S-1 a restated scope replaces the previous one" test "$(scope_of)" = '["src/one/**"]'

OUT=$(cd "$S1" && bash "$TIER" set standard "r" --scope "/etc/passwd" 2>&1); ST=$?
check "S-1 an absolute scope entry is refused" test "$ST" -eq 1
check "S-1 the refusal says the entry is absolute" reports "absolute"

OUT=$(cd "$S1" && bash "$TIER" set standard "r" --scope "" 2>&1); ST=$?
check "S-1 an empty scope is refused" test "$ST" -eq 1

OUT=$(cd "$S1" && bash "$TIER" set standard "r" 2>&1)
check "S-1 a ledger without --scope declares no scope" test "$(jq -r 'has("scope")' "$S1/.claude/task-tier.json")" = "true"

# V-3: HOME unset means no tracker is reachable: the degraded path, not an unbound-variable crash.
V3="$SB/home-unset"; mkdir -p "$V3"
git -C "$V3" init -q -b feat/no-home
git -C "$V3" config user.email t@example.invalid; git -C "$V3" config user.name t
printf 'a\n' > "$V3/a.txt"; git -C "$V3" add -A; git -C "$V3" commit -qm "init"
OUT=$(cd "$V3" && env -u HOME bash "$TIER" set standard "r" 2>&1); ST=$?
check "V-3 HOME unset set standard exits 0" test "$ST" -eq 0
check "V-3 HOME unset writes the standard ledger" test "$(jq -r .tier "$V3/.claude/task-tier.json" 2>/dev/null)" = "standard"
check "V-3 HOME unset prints no unbound variable" bash -c '! grep -qF "unbound variable" <<< "$0"' "$OUT"

[ "$fail" -eq 0 ] && echo "task-tier.test.sh PASS"
exit "$fail"
