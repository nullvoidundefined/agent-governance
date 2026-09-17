#!/usr/bin/env bash
# prose-flags.sh: an advisory pass over a document for the documentation-create
# skill's red flags (2026-09-17 skills audit, S-13). Four of the skill's seven
# red flags are detectable with acceptable false positives; this prints each
# candidate line with the flag it trips so the author looks there. It never
# decides a sentence is wrong (that stays with the skill's four-fault table)
# and never fails a turn: exit 0 always, the count on the last line.
#
#   SUPERLATIVE  "the most", "the best", "the worst", "the sharpest", "the
#                least" with no "because" on the line (a ranking without its
#                criterion).
#   COMPARATIVE  "<word>er than" (a comparison that may name one side only).
#   ABSOLUTE     "never", "cannot", "always" (a claim about behaviour the
#                author has to have executed).
#   COUNT        a number or number word, an optional adjective, then a plural
#                noun, with no colon on the line and no list item as the next
#                non-blank line (a count whose items are withheld).
# Headings, list items, table rows, and code lines are skipped.
#
# Usage: prose-flags.sh <file> [more files...]
set -uo pipefail
[ $# -gt 0 ] || { echo "usage: prose-flags.sh <file> [more files...]" >&2; exit 2; }

total=0
for file in "$@"; do
  [ -f "$file" ] || { echo "prose-flags: no such file: $file" >&2; continue; }
  flags=$(awk -v F="$file" '
    function flag(kind, n, text) { printf "%s:%d: %s: %s\n", F, n, kind, text }
    { lines[NR] = $0 }
    END {
      for (n = 1; n <= NR; n++) {
        line = lines[n]; low = tolower(line)
        if (line ~ /^[[:space:]]*(#|-|\*|[0-9]+\.|\||`)/) continue
        if (low ~ /(^|[^a-z])the (most|best|worst|sharpest|least)([^a-z]|$)/ && low !~ /(^|[^a-z])because([^a-z]|$)/) flag("SUPERLATIVE", n, line)
        if (low ~ /(^|[^a-z])[a-z]+er than([^a-z]|$)/ && low !~ /(^|[^a-z])(other|rather|whether|either|neither|further) than([^a-z]|$)/) flag("COMPARATIVE", n, line)
        if (low ~ /(^|[^a-z])(never|cannot|always)([^a-z]|$)/) flag("ABSOLUTE", n, line)
        if (low ~ /(^|[^a-z0-9])([0-9]+|two|three|four|five|six|seven|eight|nine|ten) ([a-z]+ )?[a-z]+s([^a-z]|$)/ && line !~ /:/) {
          # The list must be what comes next (blank lines allowed), not a
          # list that happens to follow some other sentence.
          listed = 0
          for (k = n + 1; k <= NR; k++) {
            if (lines[k] ~ /^[[:space:]]*$/) continue
            if (lines[k] ~ /^[[:space:]]*(-|\*|[0-9]+\.)[[:space:]]/) listed = 1
            break
          }
          if (!listed) flag("COUNT", n, line)
        }
      }
    }
  ' "$file")
  if [ -n "$flags" ]; then
    printf '%s\n' "$flags"
    total=$((total + $(printf '%s\n' "$flags" | grep -c .)))
  fi
done
echo "prose-flags: $total candidate line(s); each is a place to look, not a verdict (documentation-create, Red flags)"
exit 0
