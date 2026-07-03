#!/usr/bin/env bash
# session-start.sh
#
# SessionStart hook for Claude Code. Emits the global memory INDEX and
# any recent project handoff doc as additionalContext, so every session
# begins with the cross-session and cross-project context already in
# view. Enforces R-002 and R-001 in ~/.claude/CLAUDE.md.
#
# Why this exists: R-002 and R-001 say every session starts by reading
# global memory and the most recent handoff doc. Without a hook, the
# rule is honor-system; sessions skip the read under pressure and
# re-derive context from git log instead. This hook forces the read
# by injecting the content as session context at startup.
#
# How it works: Claude Code SessionStart hook can emit JSON with
# `hookSpecificOutput.additionalContext` as a string. Claude receives
# that string as part of its starting context for the session. This
# script reads ~/.claude/global-memory/INDEX.md and the most recent
# handoff doc under $PWD/docs/audits/ (if present), concatenates them
# with headers, and emits the result as additionalContext.
#
# The hook also surfaces any retirement candidates written into
# ~/.claude/global-memory/retirement_candidates.md by a prior session.
# That file does not exist until a retirement scan has written it, so
# the hook tolerates its absence silently.
#
# To test manually:
#   echo '{}' | ~/.claude/hooks/session-start.sh
# Should print JSON with hookSpecificOutput.additionalContext containing
# the INDEX and any handoff doc content.

set -euo pipefail

GLOBAL_MEMORY_INDEX="$HOME/.claude/global-memory/INDEX.md"
RETIREMENT_CANDIDATES="$HOME/.claude/global-memory/retirement_candidates.md"

# Buffer the context we will emit.
CTX=""

if [ -f "$GLOBAL_MEMORY_INDEX" ]; then
  CTX+=$'## Global memory index (auto-loaded per R-002 / R-001)\n\n'
  CTX+="$(cat "$GLOBAL_MEMORY_INDEX")"
  CTX+=$'\n\n'
fi

# Look for the most recent handoff doc under $PWD/docs/audits/.
# Prefer session-handoff files; fall back to the newest dated audit.
HANDOFF=""
if [ -d "docs/audits" ]; then
  HANDOFF=$(ls -1t docs/audits/*session-handoff*.md 2>/dev/null | head -1 || true)
  if [ -z "$HANDOFF" ]; then
    HANDOFF=$(ls -1t docs/audits/????-??-??-*.md 2>/dev/null | head -1 || true)
  fi
fi

if [ -n "$HANDOFF" ] && [ -f "$HANDOFF" ]; then
  CTX+=$'## Most recent handoff doc (auto-loaded per R-001)\n\nPath: '
  CTX+="$HANDOFF"
  CTX+=$'\n\n'
  # Cap at first 400 lines to avoid flooding the session start context.
  CTX+="$(head -400 "$HANDOFF")"
  CTX+=$'\n\n'
fi

if [ -f "$RETIREMENT_CANDIDATES" ] && [ -s "$RETIREMENT_CANDIDATES" ]; then
  CTX+=$'## Retirement candidates (auto-loaded from prior session)\n\n'
  CTX+="$(cat "$RETIREMENT_CANDIDATES")"
  CTX+=$'\n\n'
fi

# Capture HEAD SHA for velocity metrics (R-602).
# The session-end hook reads this to compute commit counts.
if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  git rev-parse HEAD 2>/dev/null > "${TMPDIR:-/tmp}/claude-session-start-sha" || true
fi

# If we have nothing to emit, exit silently.
if [ -z "$CTX" ]; then
  exit 0
fi

# Emit the JSON with additionalContext. jq handles the escaping for us.
jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'

exit 0
