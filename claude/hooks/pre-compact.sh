#!/usr/bin/env bash
# pre-compact.sh
#
# PreCompact hook for Claude Code. Records that a compaction happened so the
# post-compact-rules.sh UserPromptSubmit hook can re-inject the critical rules
# on the next user turn.
#
# PreCompact cannot inject context. Its hookSpecificOutput has no schema
# variant, so any object carrying additionalContext is rejected whole with
# "(root): Invalid input" and the payload is silently dropped. This hook did
# exactly that from its creation until 2026-08-06, modeled on session-start.sh,
# whose identical shape is valid because SessionStart does have a variant.
# PreCompact's only supported outcome is blocking the compaction.
#
# The rules themselves live in post-compact-rules.sh, which is the hook that
# can actually emit them. This script only sets the flag.
#
# Manual test:
#   echo '{}' | ~/.claude/hooks/pre-compact.sh; echo "exit=$?"
#   test -f ~/.claude/.post-compact-pending && echo "sentinel set"
# Should print nothing, exit 0, and leave the sentinel in place.

set -euo pipefail

SENTINEL="$HOME/.claude/.post-compact-pending"

# Never fail a compaction over the sentinel: a non-writable HOME would
# otherwise turn a missing rule reminder into a blocked compaction.
: > "$SENTINEL" 2>/dev/null || true

# Emit nothing. PreCompact accepts no context payload, and any non-empty
# object risks tripping validation again.
exit 0
