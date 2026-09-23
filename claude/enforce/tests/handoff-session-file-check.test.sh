#!/usr/bin/env bash
# Covers: hook:handoff-check
# handoff-session-file-check.test.sh: verifies the per-session handoff
# directions of hooks/handoff-check.sh (IAN-260, spec
# docs/superpowers/specs/2026-09-20-handoff-per-session-files-design.md).
#
# R-602 used to name one overwritten file. Six sessions wrote it on
# 2026-09-20 and the 8192-byte cap forced four of them to be folded by hand,
# which lost content twice over. A session now writes its own
# docs/session-handoff/YYYY-MM-DD-<slug>.md, and session-handoff.md becomes a
# capped index that lists them.
#
# The two kinds share one section contract and differ only in the cap and in
# the index's `## Sessions` list:
#
#   path                                   cap    6 sections  SHA   Sessions
#   docs/session-handoff/session-handoff.md  8192   yes        yes   yes
#   docs/session-handoff/2026-09-20-x.md     none   yes        yes   no
#
# The cap is dropped on session files deliberately: a session file is written
# by exactly one session and is never contended, so there is nothing for a cap
# to protect, and the cap is precisely what forced the lossy folds.
#
# The index directions that already existed (cap, sections, SHA) stay in
# handoff-check.test.sh unchanged. This file is new rather than an extension
# of that one because editing a tracked fixture emits a manifest content-drift
# line naming no path, which drift_is_confined cannot tolerate, so a slice
# editing one can never reach a clean RED.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/handoff-check.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF "$1" <<< "$OUT"; }
silent() { [ -z "$OUT" ]; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"; mkdir -p "$REPO/docs/session-handoff"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"
SHA=$(git -C "$REPO" rev-parse --short HEAD)

SESSION_FILE="$REPO/docs/session-handoff/2026-09-20-ian260-split.md"
INDEX="$REPO/docs/session-handoff/session-handoff.md"

# The six sections, in order, with a resolving SHA. Shared by both kinds.
sections() {
cat <<EOF
# Session Handoff: test

## 1. Last commit
- \`$SHA\` init

## 2. Production state
- fine

## 3. Session metrics
- Commits this session: 1

## 4. What shipped
- a.txt

## 5. Pending
- nothing

## 6. Next session
- README
EOF
}

run() { jq -n --arg p "$1" --rawfile c "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}' | bash "$HOOK" 2>&1; }

# --- A compliant session file is silent, exactly as a compliant index is. ---
sections > "$SB/session-good.md"
OUT=$(run "$SESSION_FILE" "$SB/session-good.md")
check "compliant session file is silent" silent

# --- The cap does not apply to a session file. This is the whole point of
# the split: the fold that lost content was forced by the cap, and a file no
# other session writes has nothing to protect. A 12KB session file, the size
# of the unfolded 2026-09-20 union, must pass. ---
{ sections; printf 'x%.0s' $(seq 1 12000); printf '\n'; } > "$SB/session-big.md"
BIG=$(wc -c < "$SB/session-big.md" | tr -d ' ')
check "the oversized-session fixture really is over 8192 bytes" test "$BIG" -gt 8192
OUT=$(run "$SESSION_FILE" "$SB/session-big.md")
check "a session file over the cap is silent" silent

# --- Negative control: the index is still capped. Dropping the cap on
# session files must not drop it on the one contended file. ---
{ index; printf 'x%.0s' $(seq 1 12000); printf '\n'; } > "$SB/index-big.md"
OUT=$(run "$INDEX" "$SB/index-big.md")
check "an oversized index is still named" reports "over the 8 KB cap"

# --- A session file still owes the six sections in order and a SHA. The cap
# is the only check that differs, so a session file missing a section must be
# named just as the index would be. ---
sections | sed 's/^## 3. Session metrics/## 3. Timings/' > "$SB/session-nometrics.md"
OUT=$(run "$SESSION_FILE" "$SB/session-nometrics.md")
check "session file missing a section is named" reports "no section for: session metrics"

sections | sed "s/\`$SHA\` init/no sha here/" > "$SB/session-nosha.md"
OUT=$(run "$SESSION_FILE" "$SB/session-nosha.md")
check "session file missing a SHA is named" reports "no commit SHA in backticks"

sections | sed "s/\`$SHA\`/\`deadbeef0\`/" > "$SB/session-badsha.md"
OUT=$(run "$SESSION_FILE" "$SB/session-badsha.md")
check "session file with an unresolvable SHA is named" reports "deadbeef0 does not resolve"

# --- A compliant index stays silent, unchanged from before the split. The
# `## Sessions` list the index will owe is NOT checked here: enforcing it now
# would turn handoff-check.test.sh's compliant fixture red, and no session
# file exists for the index to list until the migration writes them. That
# direction belongs to slice 5, with the fixture update and the migration. ---
OUT=$(run "$INDEX" "$SB/session-good.md")
check "compliant index is silent" silent

# --- Path discrimination. A dated file outside the handoff directory, and an
# undated file inside it, are both other paths: the hook stays silent rather
# than applying handoff rules to a document that is not one. ---
mkdir -p "$REPO/docs/prs"
sections | sed 's/^## 3. Session metrics/## 3. Timings/' > "$SB/elsewhere.md"
OUT=$(run "$REPO/docs/prs/2026-09-20-something.md" "$SB/elsewhere.md")
check "a dated file outside the handoff directory is silent" silent

OUT=$(run "$REPO/docs/session-handoff/README.md" "$SB/elsewhere.md")
check "an undated file in the handoff directory is silent" silent

OUT=$(printf 'not json' | bash "$HOOK" 2>&1); ST=$?
check "malformed input exits 0" test "$ST" -eq 0
check "malformed input is silent" silent

[ "$fail" -eq 0 ] && echo "handoff-session-file-check.test.sh PASS"
exit "$fail"
