#!/usr/bin/env bash
# Test harness for session-end.sh rule-log routing.
#
# Runs the hook against a sandbox HOME so it reads a fake project memory
# dir and writes to throwaway logs. Covers the two bugs fixed in this
# change:
#   1. Hook must NOT embed the sanitized local cwd path in log entries
#      (it leaks a filesystem path into the public ~/.claude repo).
#   2. Dedupe must ignore the leading date, so the same fired:/miss:
#      line is not re-appended with a fresh date every session.
#
# Run: ~/.claude/hooks/tests/session-end.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../session-end.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PROJECT_TAG="-fake-project-path-that-must-not-leak"
MEM_DIR="$SANDBOX/.claude/projects/$PROJECT_TAG/memory"
mkdir -p "$MEM_DIR"
cat > "$MEM_DIR/feedback.md" <<'EOF'
fired: R-207 no-em-dash.sh blocked an Edit; replaced with colon
miss: R-102 leaked a value via sed; gap: codify compare-in-shell
EOF

FIRES="$SANDBOX/.claude/global-memory/rule_fires.md"
MISSES="$SANDBOX/.claude/global-memory/rule_misses.md"

# Pre-seed the fires log with an identical-content entry under an OLD
# date. A correct, date-insensitive dedupe must NOT add a second copy
# when the hook runs today.
mkdir -p "$SANDBOX/.claude/global-memory"
printf '# Rule fires log\n\nheader\n\n2020-01-01 R-207 no-em-dash.sh blocked an Edit; replaced with colon\n' > "$FIRES"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

HOME="$SANDBOX" bash "$HOOK"

no_tag()      { ! grep -q -- "$PROJECT_TAG" "$1"; }
has_line()    { grep -q -- "$2" "$1"; }
count_is()    { [ "$(grep -c -- "$2" "$1")" -eq "$3" ]; }

check "no local project-path tag in fires log"  no_tag "$FIRES"
check "no local project-path tag in misses log" no_tag "$MISSES"
check "fire entry was written"  has_line "$FIRES"  "R-207 no-em-dash.sh blocked an Edit"
check "miss entry was written"  has_line "$MISSES" "R-102 MISS leaked a value via sed"
check "fire not duplicated across dates" count_is "$FIRES" "no-em-dash.sh blocked an Edit" 1

# Running the hook a second time on the same day must also not duplicate.
HOME="$SANDBOX" bash "$HOOK"
check "fire not duplicated on re-run" count_is "$FIRES" "no-em-dash.sh blocked an Edit" 1
check "miss not duplicated on re-run" count_is "$MISSES" "R-102 MISS leaked a value via sed" 1

if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "FAILURES PRESENT"
    exit 1
fi
