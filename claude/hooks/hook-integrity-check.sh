#!/usr/bin/env bash
# hook-integrity-check.sh: SessionStart guard verifying that the enforcement
# surface on disk matches the committed hash manifest. One silent Write of
# `exit 0` into a guard hook would otherwise disable it forever (2026-07-31
# security audit P1: registration and existence were checked, content never).
# Warns via additionalContext, never blocks. After INTENTIONAL hook changes,
# regenerate and commit the manifest:
#   ~/.claude/hooks/hook-integrity-check.sh --update
# Covered: hooks/*.sh, hooks/*.mjs, enforce/*.yml, enforce/*.toml,
# enforce/eslint.config.mjs, enforce/lint.mjs, enforce/manifest.json.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_INTEGRITY_ROOT:-$HOME/.claude}"
HASH_FILE="$CLAUDE_DIR/enforce/hook-hashes.txt"

compute_hashes() {
  (cd "$CLAUDE_DIR" && { ls hooks/*.sh hooks/*.mjs enforce/*.yml enforce/*.toml enforce/eslint.config.mjs enforce/lint.mjs enforce/manifest.json 2>/dev/null || true; } \
    | sort | { xargs shasum -a 256 2>/dev/null || true; })
}

if [ "${1:-}" = "--update" ]; then
  compute_hashes > "$HASH_FILE"
  echo "hook-integrity-check: wrote $(wc -l < "$HASH_FILE" | tr -d ' ') hashes to $HASH_FILE"
  exit 0
fi

cat >/dev/null 2>&1 || true   # drain stdin

[ -f "$HASH_FILE" ] || exit 0

DRIFT=$(compute_hashes | diff "$HASH_FILE" - 2>/dev/null | grep -E '^[<>]' | awk '{print $NF}' | sort -u | tr '\n' ' ' || true)

if [ -n "$DRIFT" ]; then
  jq -n --arg d "$DRIFT" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("Hook-integrity guard (R-203): enforcement files on disk do NOT match the committed hash manifest: " + $d + ". If you or the user changed these intentionally, run `~/.claude/hooks/hook-integrity-check.sh --update` and commit the manifest with the change. If not, a hook may have been tampered with: diff the files against git before trusting any gate this session.")
    }
  }'
fi
exit 0
