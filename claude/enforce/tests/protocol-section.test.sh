#!/usr/bin/env bash
# protocol-section.test.sh: verifies skills/protocol/scripts/section.sh
# (2026-09-17 skills audit, S-11) against a sandbox PROTOCOL.md: no argument
# prints the whole file; "layer 2" or "2" prints only that layer's section;
# an R-NNN prints every section mentioning it; heading words match
# case-insensitively; no match lists the headings and exits 1.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SECTION="$CLAUDE_HARNESS_ROOT/skills/protocol/scripts/section.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { printf '%s' "$OUT" | grep -qF "$1"; }
not_reports() { ! printf '%s' "$OUT" | grep -qF "$1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export CLAUDE_PROTOCOL_FILE="$SB/PROTOCOL.md"
cat > "$CLAUDE_PROTOCOL_FILE" <<'EOF'
# Protocol

Intro paragraph.

## The eleven layers

### Layer 1: Memory (what came before)

Memory body line mentions R-001.

### Layer 2: Skills (capabilities, not prose)

Skills body line.

### Layer 3: Rules

Rules body line mentions R-207 and R-001.

## Changelog

- R-207 landed on 2026-07-01.
EOF

OUT=$(bash "$SECTION" 2>&1); ST=$?
check "no argument prints the whole file" test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq "$(wc -l < "$CLAUDE_PROTOCOL_FILE" | tr -d ' ')"

OUT=$(bash "$SECTION" layer 2 2>&1); ST=$?
check "layer 2 exits 0" test "$ST" -eq 0
check "layer 2 prints its heading" reports "### Layer 2: Skills"
check "layer 2 prints its body" reports "Skills body line"
check "layer 2 omits layer 3" not_reports "Rules body line"
check "layer 2 omits the changelog" not_reports "Changelog"
OUT=$(bash "$SECTION" 3 2>&1)
check "bare number selects the layer" reports "### Layer 3: Rules"

OUT=$(bash "$SECTION" R-207 2>&1); ST=$?
check "rule id exits 0" test "$ST" -eq 0
check "rule id prints the layer mentioning it" reports "Rules body line mentions R-207"
check "rule id prints the changelog mentioning it" reports "R-207 landed"
check "rule id omits layers not mentioning it" not_reports "Skills body line"

OUT=$(bash "$SECTION" MEMORY 2>&1)
check "heading words match case-insensitively" reports "Memory body line"
check "heading words omit other layers" not_reports "Skills body line"

OUT=$(bash "$SECTION" nonsense words 2>&1); ST=$?
check "no match exits 1" test "$ST" -eq 1
check "no match lists the headings" reports "### Layer 2: Skills"

OUT=$(CLAUDE_PROTOCOL_FILE="$SB/missing.md" bash "$SECTION" 2>&1); ST=$?
check "missing file exits 1" test "$ST" -eq 1

[ "$fail" -eq 0 ] && echo "protocol-section.test.sh PASS"
exit "$fail"
