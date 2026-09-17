#!/usr/bin/env bash
# Covers: hook:enforcement-guard-check
#
# Verifies R-516's second clause, "ship a fixture test", which until 2026-09-17
# was enforced by nothing (audit P2-3). R-516's first clause is checked by
# enforcement-guard-check.sh in both directions; the fixture half was left to
# recall, and four enforcers had drifted into the manifest with no fixture
# exercising them at all.
#
# The mapping is declared, not guessed. Each fixture names the enforcers it
# proves in a `# Covers:` header line, and this check compares those
# declarations against the manifest in both directions:
#
#   manifest enforcer with no declaration -> FAIL (the R-516 gap)
#   declaration naming no manifest enforcer -> FAIL (a stale claim)
#
# A grep for the enforcer's own name was tried first and rejected: several
# enforcers are covered behaviourally rather than by name (`eslint:no-cycle`
# and `eslint:no-restricted-paths` are proven by import-direction.test.sh,
# which never spells either), so a name grep reports coverage gaps that are
# not real and teaches everyone to ignore it. A declaration costs one line and
# sits beside the assertions that justify it, where whoever edits the test will
# see it, rather than in a second column of the manifest that nobody reading a
# test ever looks at.
#
# What this cannot check: that a declared fixture's assertions really exercise
# the enforcer. A dishonest `# Covers:` line passes. The closure is over the
# enumeration, not over the proof, and that limit is the honest reading of it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_ROOT="$SCRIPT_DIR/../.."
MANIFEST="${CLAUDE_MANIFEST_FILE:-$CLAUDE_ROOT/enforce/manifest.json}"
MIN_ENFORCERS=40

fail=0

[ -f "$MANIFEST" ] || { echo "FAIL: no manifest at $MANIFEST"; exit 1; }

MANIFEST_ENFORCERS=$(jq -r '[.rules[].enforcer] | unique | .[]' "$MANIFEST" | sort -u)
ENFORCER_COUNT=$(printf '%s\n' "$MANIFEST_ENFORCERS" | grep -c . || true)
if [ "$ENFORCER_COUNT" -lt "$MIN_ENFORCERS" ]; then
  echo "FAIL: read $ENFORCER_COUNT enforcers from $MANIFEST, expected at least $MIN_ENFORCERS; the manifest is truncated or not this repo's, so this fixture proved nothing"
  exit 1
fi

# Declarations from both fixture trees. One header line may name several
# enforcers, comma separated.
DECLARED=$(grep -rhE '^# Covers:' "$CLAUDE_ROOT/enforce/tests" "$CLAUDE_ROOT/hooks/tests" 2>/dev/null \
  | sed -E 's/^# Covers:[[:space:]]*//' | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | grep -E '^[a-z]+:' | sort -u)
DECLARED_COUNT=$(printf '%s\n' "$DECLARED" | grep -c . || true)
if [ "$DECLARED_COUNT" -eq 0 ]; then
  echo "FAIL: no '# Covers:' declaration found in either fixture tree, so nothing could be compared"
  exit 1
fi

while IFS= read -r enforcer; do
  [ -n "$enforcer" ] || continue
  printf '%s\n' "$DECLARED" | grep -qxF "$enforcer" || {
    echo "FAIL: $enforcer is in the manifest with no fixture declaring it (R-516: a rule whose enforcer ships no fixture depends on recall). Add the case, then declare it in that fixture's '# Covers:' header."
    fail=1
  }
done <<< "$MANIFEST_ENFORCERS"

while IFS= read -r enforcer; do
  [ -n "$enforcer" ] || continue
  printf '%s\n' "$MANIFEST_ENFORCERS" | grep -qxF "$enforcer" || {
    echo "FAIL: a fixture declares '$enforcer', which no manifest rule names; the enforcer was renamed or retired and the declaration is now a false claim of coverage"
    fail=1
  }
done <<< "$DECLARED"

[ "$fail" -eq 0 ] && echo "manifest-fixture-closure.test.sh PASS ($ENFORCER_COUNT enforcers, $DECLARED_COUNT declared)"
exit "$fail"
