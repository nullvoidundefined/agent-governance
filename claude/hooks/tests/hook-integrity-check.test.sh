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

rm -rf "$FIX"
echo "hook-integrity-check.test.sh PASS"
