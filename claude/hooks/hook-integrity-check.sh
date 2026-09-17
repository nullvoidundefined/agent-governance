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
# (custom ESLint rules), enforce/*.sh (tdd.sh, resolve-outgoing-base.sh),
# enforce/manifest.json, enforce/lexicon.json, enforce/role-policy.json,
# enforce/tests/*.sh and hooks/tests/*.sh (the fixture suites),
# enforce/judge-prompt.md, enforce/package.json, enforce/package-lock.json.
# enforce/rules/ and lexicon.json joined 2026-09-04: a custom rule body and the
# naming registry decide what the gate enforces, so an unnoticed edit to either
# silently weakens it exactly the way an edited hook would.
# tdd.sh and role-policy.json joined 2026-09-06: the script decides what a RED
# and a GREEN are, and the policy decides what each role may write.
# The two fixture suites, the judge prompt, and the npm manifests joined
# 2026-09-17 (audit P1-2): a gutted fixture is easier to hide than a gutted
# hook, since the suite still reports ok and the dashboard stays green; the
# judge prompt decides what the llm-judge tier asks; and package-lock.json pins
# the ESLint that a third of the manifest's rules run on. The cost is deliberate
# and was chosen knowingly: editing a fixture now means running --update and
# committing the manifest in the same commit, the same contract hook edits
# already had. Not covered: translate/*.mjs, which sits outside the synced
# surface entirely (sync.sh copies claude/ only), so it cannot be hashed
# against a live install; enforce/gate-trusted-repos.txt, which is gitignored
# (client-identifying, R-106); and enforce/node_modules, which is not tracked.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_INTEGRITY_ROOT:-$HOME/.claude}"
HASH_FILE="$CLAUDE_DIR/enforce/hook-hashes.txt"

compute_hashes() {
  (
    cd "$CLAUDE_DIR" 2>/dev/null || return 0
    # The list is built and checked for emptiness before shasum sees it. An
    # empty list piped into `xargs shasum` does not run zero commands: GNU
    # xargs invokes shasum once with no operands, shasum reads stdin instead,
    # and the result is a single hash of empty input under the filename `-`.
    # --update would then write that one bogus line over a real manifest and
    # report success (2026-09-17 audit P1-1).
    local files
    files=$({ ls hooks/*.sh hooks/*.mjs hooks/*.py hooks/tests/*.sh enforce/*.sh enforce/*.yml enforce/*.toml enforce/*.mjs enforce/rules/*.mjs enforce/tests/*.sh enforce/manifest.json enforce/lexicon.json enforce/role-policy.json enforce/judge-prompt.md enforce/package.json enforce/package-lock.json 2>/dev/null || true; } | sort)
    [ -n "$files" ] || return 0
    printf '%s\n' "$files" | { xargs shasum -a 256 2>/dev/null || true; }
  )
}

if [ "${1:-}" = "--update" ]; then
  NEW_HASHES=$(compute_hashes)
  NEW_COUNT=$(printf '%s' "$NEW_HASHES" | grep -c . || true)
  # Two floors, because this command overwrites the only record of what the
  # enforcement surface is supposed to be, and it used to do so from any
  # directory at all (audit P1-1). Neither floor blocks a legitimate change;
  # both block an accident pointed at the wrong or a half-populated tree.
  if [ "$NEW_COUNT" -eq 0 ]; then
    echo "hook-integrity-check: REFUSED to write $HASH_FILE: computed zero hashes, so CLAUDE_DIR=$CLAUDE_DIR holds no enforcement files. The existing manifest is untouched." >&2
    exit 1
  fi
  if [ -f "$HASH_FILE" ] && [ "${2:-}" != "--force" ]; then
    OLD_COUNT=$(grep -c . "$HASH_FILE" || true)
    if [ "$OLD_COUNT" -gt 0 ] && [ $((NEW_COUNT * 2)) -lt "$OLD_COUNT" ]; then
      echo "hook-integrity-check: REFUSED to write $HASH_FILE: would shrink the manifest from $OLD_COUNT entries to $NEW_COUNT, which usually means CLAUDE_DIR=$CLAUDE_DIR is a partial tree. Re-run with --force if the enforcement surface really did shrink that far." >&2
      exit 1
    fi
  fi
  printf '%s\n' "$NEW_HASHES" > "$HASH_FILE"
  echo "hook-integrity-check: wrote $NEW_COUNT hashes to $HASH_FILE"
  exit 0
fi

cat >/dev/null 2>&1 || true   # drain stdin

# An absent manifest used to exit 0 in silence, which made deleting one file
# the whole bypass: with no manifest, a hook rewritten to `exit 0` drew no
# warning and the session proceeded as though every gate were intact (audit
# P1-1). The manifest is committed, so on any synced install it is present;
# its absence means an unsynced tree or a deletion, and both are worth saying.
if [ ! -f "$HASH_FILE" ]; then
  jq -n --arg f "$HASH_FILE" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("Hook-integrity guard (R-203): the hash manifest is MISSING at " + $f + ", so nothing verified that this session'"'"'s hooks and enforcement files match what the repo committed. Enforcement integrity is unverified, not intact. Run ./sync.sh from the agent-governance checkout if this install is stale, and treat a manifest that vanished from a synced tree as a tampering signal: diff the hook tree against git before trusting any gate this session.")
    }
  }'
  exit 0
fi

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
