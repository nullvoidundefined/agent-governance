#!/usr/bin/env bash
# prose-flags.test.sh: verifies skills/documentation-create/scripts/prose-flags.sh
# (2026-09-17 skills audit, S-13): each of the four flags fires on a matching
# prose line, a superlative with its "because" does not, a count followed by
# its list does not, headings and list items are skipped, and the script
# exits 0 with the count on the last line.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
PF="$CLAUDE_HARNESS_ROOT/skills/documentation-create/scripts/prose-flags.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF "$1" <<< "$OUT"; }
not_reports() { ! grep -qF "$1" <<< "$OUT"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
cat > "$SB/doc.md" <<'EOF'
# The most important heading

This is the most interesting failure in the submission.
This one matters most because it is reproducible in thirty seconds.
The scorer is weaker than the signal it feeds.
There is no path by which a weak guess can look like a strong answer, so it never happens.
They differ on six visual axes.
The five states are:
- solid
- weak
The two modes are the following ones.
- fast
- slow
- The most listed item is skipped.
EOF

OUT=$(bash "$PF" "$SB/doc.md" 2>&1); ST=$?
check "exits 0" test "$ST" -eq 0
check "superlative without because flagged" reports "doc.md:3: SUPERLATIVE:"
check "superlative with because not flagged" not_reports "doc.md:4:"
check "comparative flagged" reports "doc.md:5: COMPARATIVE:"
check "absolute flagged" reports "doc.md:6: ABSOLUTE:"
check "count without list flagged" reports "doc.md:7: COUNT:"
check "count with colon not flagged" not_reports "doc.md:8:"
check "count followed by list not flagged" not_reports "doc.md:11: COUNT"
check "heading skipped" not_reports "doc.md:1:"
check "list item skipped" not_reports "doc.md:14:"
check "count line last" bash -c "printf '%s' \"\$0\" | tail -1 | grep -q 'prose-flags: 4 candidate line(s)'" "$OUT"

OUT=$(bash "$PF" 2>&1); ST=$?
check "no argument is a usage error" test "$ST" -eq 2

[ "$fail" -eq 0 ] && echo "prose-flags.test.sh PASS"
exit "$fail"
