#!/usr/bin/env bash
# task-tier-lane.test.sh: verifies the build-fast ledger fields of
# skills/task-start/scripts/task-tier.sh (IAN-401, spec
# 2026-09-27-build-fast-design.md B-3, acceptance criterion 6).
#
# `task-tier.sh set` accepts --lane <fast|guarded>, --lane-override
# <fast|guarded>, and --merge-mode <owner|green>, and writes the ledger keys
# lane, laneOverride, and mergeMode; `summary` prints `lane <v>` and
# `merge <v>` when they are present. Any other value for those flags exits
# non-zero and leaves the ledger byte-for-byte unchanged. A later `set` on the
# same branch with the same ticket keeps each of the three fields it does not
# restate; a `set` naming another ticket, or run on another branch, drops all
# three, so a new task never inherits a lane or a merge mode. The existing
# ticket and scope handling is unchanged throughout.
#
# HOME is a sandbox without a TICKET-TRACKER.json, so no case depends on the
# tracker gate.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TIER="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF -- "$1" <<< "$OUT"; }
omits() { ! grep -qF -- "$1" <<< "$OUT"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/home/.claude"; export HOME="$SB/home"
REPO="$SB/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b feat/lanes
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/a.txt"; printf '.claude/task-tier.json\n' > "$REPO/.gitignore"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"
LEDGER="$REPO/.claude/task-tier.json"

# field <jq filter>: prints one field of the sandbox ledger ("null" when absent).
field() { jq -r "$1" "$LEDGER"; }
# tier_run <args...>: runs task-tier.sh in the sandbox repo; sets OUT and ST.
tier_run() { OUT=$(cd "$REPO" && bash "$TIER" "$@" 2>&1); ST=$?; }
# snapshot_ledger / ledger_unchanged: compare the ledger with its state before a call.
snapshot_ledger() { cp "$LEDGER" "$SB/ledger-before.json"; }
ledger_unchanged() { cmp -s "$LEDGER" "$SB/ledger-before.json"; }

# L-1: lane and merge mode are written and summarized.
tier_run set standard "lane fields" --ticket IAN-401 --lane fast --merge-mode green --scope 'docs/**'
check "L-1 set with --lane and --merge-mode exits 0" test "$ST" -eq 0
check "L-1 ledger carries lane fast" test "$(field .lane)" = "fast"
check "L-1 ledger carries mergeMode green" test "$(field .mergeMode)" = "green"
check "L-1 ledger carries no laneOverride" test "$(field .laneOverride)" = "null"
check "L-1 ticket survives" test "$(field .ticket)" = "IAN-401"
check "L-1 scope survives" test "$(field '.scope | join(",")')" = "docs/**"
tier_run summary
check "L-1 summary exits 0" test "$ST" -eq 0
check "L-1 summary prints the lane (got: $OUT)" reports "lane fast"
check "L-1 summary prints the merge mode (got: $OUT)" reports "merge green"
check "L-1 summary still names the ticket (got: $OUT)" reports "ticket IAN-401"

# L-2: --lane-override is written; every accepted value round-trips.
tier_run set standard "lane fields" --ticket IAN-401 --lane-override guarded
check "L-2 set with --lane-override exits 0" test "$ST" -eq 0
check "L-2 ledger carries laneOverride guarded" test "$(field .laneOverride)" = "guarded"
tier_run set standard "lane fields" --ticket IAN-401 --lane guarded --lane-override fast --merge-mode owner
check "L-2 guarded, fast, and owner accepted" test "$ST" -eq 0
check "L-2 ledger carries lane guarded" test "$(field .lane)" = "guarded"
check "L-2 ledger carries laneOverride fast" test "$(field .laneOverride)" = "fast"
check "L-2 ledger carries mergeMode owner" test "$(field .mergeMode)" = "owner"
tier_run summary
check "L-2 summary prints lane guarded (got: $OUT)" reports "lane guarded"
check "L-2 summary prints merge owner (got: $OUT)" reports "merge owner"

# L-3: unknown values are refused and leave the ledger unchanged.
tier_run set standard "lane fields" --ticket IAN-401 --lane fast --merge-mode green
snapshot_ledger
for badFlag in "--lane checked" "--lane-override x" "--merge-mode auto" "--lane FAST" "--merge-mode "; do
  # shellcheck disable=SC2086  # the flag and its value split on purpose
  tier_run set standard "lane fields" --ticket IAN-401 ${badFlag% *} "${badFlag#* }"
  check "L-3 '$badFlag' exits non-zero" test "$ST" -ne 0
  check "L-3 '$badFlag' leaves the ledger unchanged" ledger_unchanged
done

# L-4: a later set on the same branch and ticket keeps what it does not restate.
tier_run set standard "lane fields" --ticket IAN-401 --lane fast --lane-override guarded --merge-mode green
tier_run set standard "reclassified lane" --lane guarded
check "L-4 set with only --lane exits 0" test "$ST" -eq 0
check "L-4 lane is the restated value" test "$(field .lane)" = "guarded"
check "L-4 mergeMode kept" test "$(field .mergeMode)" = "green"
check "L-4 laneOverride kept" test "$(field .laneOverride)" = "guarded"
check "L-4 ticket survives" test "$(field .ticket)" = "IAN-401"
check "L-4 scope survives" test "$(field '.scope | join(",")')" = "docs/**"
tier_run set standard "restated ticket" --ticket IAN-401 --merge-mode owner
check "L-4 same ticket restated keeps lane" test "$(field .lane)" = "guarded"
check "L-4 same ticket restated keeps laneOverride" test "$(field .laneOverride)" = "guarded"
check "L-4 same ticket restated records merge owner" test "$(field .mergeMode)" = "owner"

# L-5: a set naming another ticket drops all three fields.
tier_run set standard "lane fields" --ticket IAN-401 --lane fast --lane-override guarded --merge-mode green
tier_run set standard "next task" --ticket IAN-402
check "L-5 set with another ticket exits 0" test "$ST" -eq 0
check "L-5 lane dropped" test "$(field .lane)" = "null"
check "L-5 laneOverride dropped" test "$(field .laneOverride)" = "null"
check "L-5 mergeMode dropped" test "$(field .mergeMode)" = "null"
check "L-5 the new ticket is recorded" test "$(field .ticket)" = "IAN-402"
check "L-5 scope survives on the same branch" test "$(field '.scope | join(",")')" = "docs/**"
tier_run summary
check "L-5 summary prints no lane (got: $OUT)" bash -c '! grep -qE "lane (fast|guarded)" <<< "$0"' "$OUT"
check "L-5 summary prints no merge mode (got: $OUT)" bash -c '! grep -qE "merge (owner|green)" <<< "$0"' "$OUT"

# L-6: a set on another branch drops all three fields, even for the same ticket.
tier_run set standard "lane fields" --ticket IAN-401 --lane fast --lane-override guarded --merge-mode green
git -C "$REPO" checkout -q -b feat/other
tier_run set standard "other branch" --ticket IAN-401 --scope 'src/**'
check "L-6 set on another branch exits 0" test "$ST" -eq 0
check "L-6 ledger names the new branch" test "$(field .branch)" = "feat/other"
check "L-6 lane dropped" test "$(field .lane)" = "null"
check "L-6 laneOverride dropped" test "$(field .laneOverride)" = "null"
check "L-6 mergeMode dropped" test "$(field .mergeMode)" = "null"
check "L-6 ticket recorded" test "$(field .ticket)" = "IAN-401"
check "L-6 scope recorded" test "$(field '.scope | join(",")')" = "src/**"
tier_run summary
check "L-6 summary prints no lane (got: $OUT)" omits "lane fast"
check "L-6 summary prints no merge mode (got: $OUT)" omits "merge green"

[ "$fail" -eq 0 ] || exit 1
echo "task-tier-lane.test.sh PASS"
