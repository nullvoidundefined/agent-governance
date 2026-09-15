#!/usr/bin/env bash
# hook-integrity-check.sh: SessionStart guard verifying that the enforcement
# surface on disk matches the committed hash manifest. One silent Write of
# `exit 0` into a guard hook would otherwise disable it forever (2026-07-31
# security audit P1: registration and existence were checked, content never).
# Warns via additionalContext, never blocks. After INTENTIONAL hook changes,
# regenerate and commit the manifest:
#   ~/.claude/hooks/hook-integrity-check.sh --update
# Covered: hooks/*.sh, hooks/*.mjs, hooks/*.py, enforce/*.yml, enforce/*.toml,
# enforce/*.mjs (lint, ratchet, eslint config, shared options), enforce/rules/*.mjs
# (custom ESLint rules), enforce/*.sh (tdd.sh, resolveOutgoingBase.sh),
# enforce/manifest.json, enforce/lexicon.json, enforce/role-policy.json.
# enforce/rules/ and lexicon.json joined 2026-09-04: a custom rule body and the
# naming registry decide what the gate enforces, so an unnoticed edit to either
# silently weakens it exactly the way an edited hook would.
# tdd.sh and role-policy.json joined 2026-09-06: the script decides what a RED
# and a GREEN are, and the policy decides what each role may write.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_INTEGRITY_ROOT:-$HOME/.claude}"
HASH_FILE="$CLAUDE_DIR/enforce/hook-hashes.txt"

compute_hashes() {
  (cd "$CLAUDE_DIR" && { ls hooks/*.sh hooks/*.mjs hooks/*.py enforce/*.sh enforce/*.yml enforce/*.toml enforce/*.mjs enforce/rules/*.mjs enforce/manifest.json enforce/lexicon.json enforce/role-policy.json 2>/dev/null || true; } \
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

# Second mode (2026-09-16 audit P2-11): the manifest above compares the live
# copy against a file that lives in the same live copy, so a hand-edit plus
# `--update` is self-consistent and invisible. When sync.sh has stamped its
# source (.sync-source), also compare the live tree against the repo
# checkout it was synced from; post-migration nothing else asserts the two
# agree, a property `git status` used to provide for free.
SOURCE_DRIFT=""
SYNC_SOURCE_FILE="$CLAUDE_DIR/.sync-source"
if [ -f "$SYNC_SOURCE_FILE" ]; then
  REPO_CLAUDE="$(cat "$SYNC_SOURCE_FILE" 2>/dev/null)/claude"
  if [ -d "$REPO_CLAUDE" ]; then
    SOURCE_DRIFT=$(diff <(CLAUDE_DIR="$REPO_CLAUDE"; compute_hashes) <(compute_hashes) 2>/dev/null | grep -E '^[<>]' | awk '{print $NF}' | sort -u | tr '\n' ' ' || true)
  fi
fi

if [ -n "$DRIFT" ] || [ -n "$SOURCE_DRIFT" ]; then
  MSG=""
  [ -n "$DRIFT" ] && MSG="Hook-integrity guard (R-203): enforcement files on disk do NOT match the committed hash manifest: ${DRIFT}. If you or the user changed these intentionally, run \`~/.claude/hooks/hook-integrity-check.sh --update\` and commit the manifest with the change. If not, a hook may have been tampered with: diff the files against git before trusting any gate this session. "
  [ -n "$SOURCE_DRIFT" ] && MSG="${MSG}Hook-integrity guard (R-203/P2-11): the live ~/.claude enforcement surface does not match the repo checkout it syncs from: ${SOURCE_DRIFT}. Run sync.sh from the repo if the repo is newer; diff the live file against the repo before trusting it if not."
  jq -n --arg m "$MSG" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $m
    }
  }'
fi
exit 0
