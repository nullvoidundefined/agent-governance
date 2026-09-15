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

rm -rf "$FIX" "$REPO_FIX"
echo "hook-integrity-check.test.sh PASS"
