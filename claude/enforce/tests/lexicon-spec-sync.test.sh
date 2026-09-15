#!/usr/bin/env bash
# Verifies that rulebook/reference.md's R-316 verb lists are generated from
# enforce/lexicon.json and cannot drift from it.
#
# The 2026-09-04 config audit filed this as a P3: the registry and the Spec
# bullet were "one rule in two forms", kept in step by an instruction to edit
# both together. They were already out of step twice, once with the registry
# banning `fetch`/`drop`/`remove` that the bullet approved, and once with the
# registry banning 22 synonyms where the bullet listed 6.
#
# Five invariants:
#   1. reference.md carries both markers.
#   2. --check passes on the committed tree.
#   3. --check FAILS when the registry changes and the prose does not. This is
#      the one that matters: a sync check that cannot fail is decoration.
#   4. --write brings them back into agreement, and is idempotent.
#   5. A registry that contradicts itself is rejected outright. Found while
#      writing case 3: banning a verb while verbGroups/scopeVerbs still bound it
#      to a layer rendered it as both the layer's read verb and a banned
#      synonym, and nothing objected.
set -euo pipefail
E="$HOME/.claude/enforce"
REFERENCE="$HOME/.claude/rulebook/reference.md"

# 1. Markers present.
grep -q '<!-- lexicon:begin -->' "$REFERENCE" || { echo "FAIL: reference.md has no lexicon:begin marker"; exit 1; }
grep -q '<!-- lexicon:end -->' "$REFERENCE" || { echo "FAIL: reference.md has no lexicon:end marker"; exit 1; }

# 2. Committed tree is in sync.
node "$E/renderLexiconSpec.mjs" --check >/dev/null 2>&1 || {
  echo "FAIL: reference.md is out of sync with lexicon.json. Run: node enforce/renderLexiconSpec.mjs --write"
  exit 1
}

# 3. Drift must be detected. Work on a copy of the whole enforce tree plus the
# rulebook so the real files are never touched, then ban a verb in the copy and
# assert --check notices.
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/enforce" "$SANDBOX/rulebook"
cp "$E/renderLexiconSpec.mjs" "$E/lexicon.json" "$SANDBOX/enforce/"
cp "$REFERENCE" "$SANDBOX/rulebook/reference.md"

# A coherent change: ban a verb that no group or scope table references, so the
# only thing that shifts is the rendered prose.
node -e '
  const fs = require("fs");
  const path = process.argv[1];
  const lexicon = JSON.parse(fs.readFileSync(path, "utf8"));
  lexicon.bannedVerbs.yoink = "get";
  fs.writeFileSync(path, JSON.stringify(lexicon, null, 2) + "\n");
' "$SANDBOX/enforce/lexicon.json"

if node "$SANDBOX/enforce/renderLexiconSpec.mjs" --check >/dev/null 2>&1; then
  echo "FAIL: --check passed after the registry changed; the sync check cannot detect drift"
  exit 1
fi

# 4. --write reconciles, and running it again is a no-op.
node "$SANDBOX/enforce/renderLexiconSpec.mjs" --write >/dev/null
node "$SANDBOX/enforce/renderLexiconSpec.mjs" --check >/dev/null 2>&1 || {
  echo "FAIL: --write did not bring reference.md back into sync"
  exit 1
}
BEFORE=$(shasum -a 256 "$SANDBOX/rulebook/reference.md" | cut -d' ' -f1)
node "$SANDBOX/enforce/renderLexiconSpec.mjs" --write >/dev/null
AFTER=$(shasum -a 256 "$SANDBOX/rulebook/reference.md" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: --write is not idempotent ($BEFORE vs $AFTER)"; exit 1; }

# The reconciled copy must actually reflect the change, not just parse.
grep -q 'yoink' "$SANDBOX/rulebook/reference.md" || {
  echo "FAIL: the regenerated prose does not carry the registry's new ban"
  exit 1
}

# 5. An internally contradictory registry is rejected rather than rendered.
# Banning a verb that verbGroups.read and scopeVerbs still bind to a layer would
# otherwise print it as both the layer's read verb and a banned synonym.
node -e '
  const fs = require("fs");
  const path = process.argv[1];
  const lexicon = JSON.parse(fs.readFileSync(path, "utf8"));
  lexicon.verbs = lexicon.verbs.filter((verb) => verb !== "fetch");
  lexicon.bannedVerbs.fetch = "get";
  fs.writeFileSync(path, JSON.stringify(lexicon, null, 2) + "\n");
' "$SANDBOX/enforce/lexicon.json"
CONTRADICTION=$(node "$SANDBOX/enforce/renderLexiconSpec.mjs" --print 2>&1 || true)
node "$SANDBOX/enforce/renderLexiconSpec.mjs" --print >/dev/null 2>&1 && {
  echo "FAIL: a registry that bans a verb its own scope table binds must be rejected"
  exit 1
} || true
printf '%s' "$CONTRADICTION" | grep -q 'contradicts itself' || {
  echo "FAIL: the rejection must say the registry contradicts itself, got: $CONTRADICTION"
  exit 1
}
printf '%s' "$CONTRADICTION" | grep -q 'verbGroups.read' || {
  echo "FAIL: the rejection must name the offending field, got: $CONTRADICTION"
  exit 1
}

echo "lexicon-spec-sync.test.sh PASS"
