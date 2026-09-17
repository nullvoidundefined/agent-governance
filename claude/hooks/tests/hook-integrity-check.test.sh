#!/usr/bin/env bash
# Verifies hook-integrity-check.sh: silent when disk matches the hash manifest,
# warns naming the file when a hook is tampered with, and --update regenerates.
set -euo pipefail
HOOK="$HOME/.claude/hooks/hook-integrity-check.sh"

FIX=$(mktemp -d)
mkdir -p "$FIX/hooks" "$FIX/enforce"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/hooks/sample-guard.sh"
printf '{"rules":[]}\n' > "$FIX/enforce/manifest.json"

# Generate the manifest -> clean check is silent.
CLAUDE_INTEGRITY_ROOT="$FIX" "$HOOK" --update >/dev/null
OUT=$(echo '{}' | CLAUDE_INTEGRITY_ROOT="$FIX" "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence when hashes match; got: $OUT"; exit 1; }

# Tamper with a hook -> warns naming it.
printf '#!/usr/bin/env bash\n# tampered\nexit 0\n' > "$FIX/hooks/sample-guard.sh"
OUT2=$(echo '{}' | CLAUDE_INTEGRITY_ROOT="$FIX" "$HOOK")
printf '%s' "$OUT2" | grep -q 'sample-guard.sh' || { echo "FAIL: expected drift warning naming sample-guard.sh"; exit 1; }

# --update accepts the change -> silent again.
CLAUDE_INTEGRITY_ROOT="$FIX" "$HOOK" --update >/dev/null
OUT3=$(echo '{}' | CLAUDE_INTEGRITY_ROOT="$FIX" "$HOOK")
[ -z "$OUT3" ] || { echo "FAIL: expected silence after --update; got: $OUT3"; exit 1; }

# Live-vs-repo mode (2026-09-16 audit P2-11): with a .sync-source stamp, the
# check also compares the live tree against the repo checkout it syncs from.
REPO_FIX=$(mktemp -d)
mkdir -p "$REPO_FIX/claude/hooks" "$REPO_FIX/claude/enforce"
cp "$FIX/hooks/sample-guard.sh" "$REPO_FIX/claude/hooks/sample-guard.sh"
cp "$FIX/enforce/manifest.json" "$REPO_FIX/claude/enforce/manifest.json"
printf '%s\n' "$REPO_FIX" > "$FIX/.sync-source"

OUT4=$(echo '{}' | CLAUDE_INTEGRITY_ROOT="$FIX" "$HOOK")
[ -z "$OUT4" ] || { echo "FAIL: expected silence when live matches the repo source; got: $OUT4"; exit 1; }

printf '#!/usr/bin/env bash\n# repo moved ahead\nexit 0\n' > "$REPO_FIX/claude/hooks/sample-guard.sh"
OUT5=$(echo '{}' | CLAUDE_INTEGRITY_ROOT="$FIX" "$HOOK")
printf '%s' "$OUT5" | grep -q 'does not match the repo checkout' || { echo "FAIL: expected live-vs-repo drift warning; got: $OUT5"; exit 1; }
printf '%s' "$OUT5" | grep -q 'sample-guard.sh' || { echo "FAIL: live-vs-repo warning must name the drifted file; got: $OUT5"; exit 1; }

# P1-1 (2026-09-17 audit): an absent manifest used to exit 0 in silence, so
# deleting one file was the entire bypass. It must warn instead.
MISSING_FIX=$(mktemp -d)
mkdir -p "$MISSING_FIX/hooks" "$MISSING_FIX/enforce"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MISSING_FIX/hooks/sample-guard.sh"
OUT6=$(echo '{}' | CLAUDE_INTEGRITY_ROOT="$MISSING_FIX" "$HOOK")
printf '%s' "$OUT6" | grep -q 'MISSING' \
  || { echo "FAIL: expected a warning when the hash manifest is absent; got: $OUT6"; exit 1; }
printf '%s' "$OUT6" | grep -q 'unverified' \
  || { echo "FAIL: the absent-manifest warning must say enforcement is unverified, not intact; got: $OUT6"; exit 1; }

# P1-1 second half: --update had no floor. Against a tree holding no
# enforcement files it wrote one bogus line (a hash of empty stdin, filename
# `-`) over the real manifest and reported success.
EMPTY_FIX=$(mktemp -d)
mkdir -p "$EMPTY_FIX/enforce"
printf 'aaaa  hooks/real-one.sh\nbbbb  hooks/real-two.sh\n' > "$EMPTY_FIX/enforce/hook-hashes.txt"
BEFORE=$(cat "$EMPTY_FIX/enforce/hook-hashes.txt")
if CLAUDE_INTEGRITY_ROOT="$EMPTY_FIX" "$HOOK" --update >/dev/null 2>&1; then
  echo "FAIL: --update against a tree with no enforcement files must refuse, not succeed"; exit 1
fi
[ "$(cat "$EMPTY_FIX/enforce/hook-hashes.txt")" = "$BEFORE" ] \
  || { echo "FAIL: the refused --update must leave the existing manifest untouched"; exit 1; }
grep -q '  -$' "$EMPTY_FIX/enforce/hook-hashes.txt" \
  && { echo "FAIL: manifest holds a hash of stdin under the filename -"; exit 1; }

# A large shrink is refused too, and --force still allows it.
SHRINK_FIX=$(mktemp -d)
mkdir -p "$SHRINK_FIX/hooks" "$SHRINK_FIX/enforce"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHRINK_FIX/hooks/only-one.sh"
printf 'x  a\nx  b\nx  c\nx  d\nx  e\nx  f\n' > "$SHRINK_FIX/enforce/hook-hashes.txt"
if CLAUDE_INTEGRITY_ROOT="$SHRINK_FIX" "$HOOK" --update >/dev/null 2>&1; then
  echo "FAIL: --update shrinking 6 entries to 1 must refuse without --force"; exit 1
fi
[ "$(grep -c . "$SHRINK_FIX/enforce/hook-hashes.txt")" -eq 6 ] \
  || { echo "FAIL: the refused shrink must leave the manifest untouched"; exit 1; }
CLAUDE_INTEGRITY_ROOT="$SHRINK_FIX" "$HOOK" --update --force >/dev/null \
  || { echo "FAIL: --force must allow a deliberate shrink"; exit 1; }
[ "$(grep -c . "$SHRINK_FIX/enforce/hook-hashes.txt")" -eq 1 ] \
  || { echo "FAIL: --force did not rewrite the manifest"; exit 1; }

rm -rf "$FIX" "$REPO_FIX" "$MISSING_FIX" "$EMPTY_FIX" "$SHRINK_FIX"
echo "hook-integrity-check.test.sh PASS"
