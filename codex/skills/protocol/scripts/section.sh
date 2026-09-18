#!/usr/bin/env bash
# section.sh: the protocol skill's loader (2026-09-17 skills audit, S-11).
# `/protocol` used to inject all of PROTOCOL.md (44 KB) for a question that
# is usually about one layer or one rule's origin. With no argument this
# still prints the whole file; with one it prints only what matches:
#   layer <N> | <N>      the "### Layer N:" section
#   R-NNN                every section that mentions the rule id
#   <words>              every section whose heading contains the words
#                        (case-insensitive)
# A section runs from a "##"/"###" heading to the next heading of the same
# or higher level. No match prints the heading index so the next call can
# name one. Never writes anything.
#
# Usage: section.sh [layer N | N | R-NNN | heading words]
# CLAUDE_PROTOCOL_FILE overrides the file (fixtures).
set -uo pipefail

FILE="${CLAUDE_PROTOCOL_FILE:-$HOME/.claude/PROTOCOL.md}"
[ -f "$FILE" ] || { echo "protocol: $FILE is not present on this machine" >&2; exit 1; }
QUERY="$*"

if [ -z "$QUERY" ]; then cat "$FILE"; exit 0; fi

# print_sections <awk predicate over the heading line, lower-cased in `h`>
print_sections() {
  awk -v mode="$1" -v want="$2" '
    function level(line) { match(line, /^#+/); return RLENGTH }
    function matches(h,   lh) {
      lh = tolower(h)
      if (mode == "layer") return lh ~ ("^### layer " want ":")
      if (mode == "heading") return index(lh, want) > 0
      return 0
    }
    /^#+ / {
      if (printing && level($0) <= plevel) { printing = 0 }
      if (!printing && matches($0)) { printing = 1; plevel = level($0); found = 1 }
    }
    printing { print }
    END { exit found ? 0 : 1 }
  ' "$FILE"
}

# print_sections_mentioning <rule id>: every section whose body mentions it.
print_sections_mentioning() {
  awk -v want="$1" '
    function level(line) { match(line, /^#+/); return RLENGTH }
    function flush() { if (buf != "" && hit) { printf "%s", buf; found = 1 } buf = ""; hit = 0 }
    /^#+ / { if (level($0) <= 3) flush() }
    { buf = buf $0 "\n"; if (index($0, want)) hit = 1 }
    END { flush(); exit found ? 0 : 1 }
  ' "$FILE"
}

lower=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]')
if grep -qE '^(layer )?[0-9]+$' <<< "$lower"; then
  n=$(printf '%s' "$lower" | grep -oE '[0-9]+')
  print_sections layer "$n" && exit 0
elif grep -qE '^R-[0-9]{3}$' <<< "$QUERY"; then
  print_sections_mentioning "$QUERY" && exit 0
else
  print_sections heading "$lower" && exit 0
fi

echo "protocol: nothing matches '$QUERY'. Headings:"
grep -E '^#{2,3} ' "$FILE"
exit 1
