#!/usr/bin/env bash
# Verifies ratchet.mjs, the long-term half of deterministic enforcement.
# Seven invariants:
#   1. No baseline is an error telling you to --update, never a silent pass.
#   2. --update writes a baseline with per-rule counts.
#   3. An unchanged tree passes.
#   4. A NEW violation fails and names the rule and the delta.
#   5. A fixed violation is reported as an improvement and still passes.
#   6. --strict fails on an improvement the baseline has not locked in.
#   7. Two --update runs on one tree are byte-identical (no timestamp churn).
set -euo pipefail
E="$HOME/.claude/enforce"

new_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  printf '{"naming":{"enabled":true}}\n' > "$dir/.enforce.json"
  mkdir -p "$dir/src/services"
  printf 'export function retrieveNote() { return 1; }\n' > "$dir/src/services/a.ts"
  printf 'export function generate() { return 1; }\n' > "$dir/src/services/b.ts"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}

REPO=$(new_repo)

# 1. Missing baseline is a hard stop with instructions.
OUT=$(node "$E/ratchet.mjs" "$REPO" 2>&1) && { echo "FAIL: a missing baseline must exit non-zero"; exit 1; } || true
printf '%s' "$OUT" | grep -q -- '--update' || { echo "FAIL: missing-baseline message must point at --update, got: $OUT"; exit 1; }

# 2. --update records per-rule counts.
node "$E/ratchet.mjs" --update "$REPO" >/dev/null
[ -f "$REPO/.enforce-baseline.json" ] || { echo "FAIL: --update must write .enforce-baseline.json"; exit 1; }
COUNT=$(jq -r '.counts["lexicon/naming"] // 0' "$REPO/.enforce-baseline.json")
[ "$COUNT" = "2" ] || { echo "FAIL: expected 2 baselined naming violations, got $COUNT"; exit 1; }

# 3. Unchanged tree passes.
node "$E/ratchet.mjs" "$REPO" >/dev/null || { echo "FAIL: an unchanged tree must pass"; exit 1; }

# 4. A new violation fails and names the rule and the delta.
printf 'export function retrieveNote() { return 1; }\n' > "$REPO/src/services/c.ts"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat: add"
OUT=$(node "$E/ratchet.mjs" "$REPO" 2>&1) && { echo "FAIL: a new violation must fail the ratchet"; exit 1; } || true
printf '%s' "$OUT" | grep -q 'lexicon/naming  2 -> 3' || { echo "FAIL: regression must name the rule and delta, got: $OUT"; exit 1; }
printf '%s' "$OUT" | grep -q 'R-204' || { echo "FAIL: regression must refuse baseline-raising as the fix, got: $OUT"; exit 1; }

# 5. Fixing below the baseline passes and reports the improvement.
printf 'export function getNote() { return 1; }\n' > "$REPO/src/services/a.ts"
printf 'export function generateNote() { return 1; }\n' > "$REPO/src/services/b.ts"
printf 'export function getOtherNote() { return 1; }\n' > "$REPO/src/services/c.ts"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "fix: names"
OUT=$(node "$E/ratchet.mjs" "$REPO" 2>&1) || { echo "FAIL: a tree below baseline must pass, got: $OUT"; exit 1; }
printf '%s' "$OUT" | grep -q 'improved' || { echo "FAIL: expected an improvement line, got: $OUT"; exit 1; }

# 6. --strict refuses an unlocked improvement.
node "$E/ratchet.mjs" --strict "$REPO" >/dev/null 2>&1 && { echo "FAIL: --strict must fail on an unlocked improvement"; exit 1; } || true

# 7. Determinism: repeated --update is byte-identical.
node "$E/ratchet.mjs" --update "$REPO" >/dev/null
FIRST=$(shasum -a 256 "$REPO/.enforce-baseline.json" | cut -d' ' -f1)
node "$E/ratchet.mjs" --update "$REPO" >/dev/null
SECOND=$(shasum -a 256 "$REPO/.enforce-baseline.json" | cut -d' ' -f1)
[ "$FIRST" = "$SECOND" ] || { echo "FAIL: two --update runs must be byte-identical ($FIRST vs $SECOND)"; exit 1; }

echo "ratchet.test.sh PASS"
