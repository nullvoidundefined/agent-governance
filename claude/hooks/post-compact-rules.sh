#!/usr/bin/env bash
# post-compact-rules.sh
#
# UserPromptSubmit hook for Claude Code. Re-injects the critical rules on the
# first user turn after a compaction, then clears the flag so the rules are not
# repeated on every prompt.
#
# The pairing exists because PreCompact cannot inject context: its
# hookSpecificOutput has no schema variant, so a payload carrying
# additionalContext is rejected whole. UserPromptSubmit does have one, so the
# work is split: pre-compact.sh sets the sentinel, this hook emits the rules.
#
# Manual test:
#   touch ~/.claude/.post-compact-pending
#   echo '{}' | ~/.claude/hooks/post-compact-rules.sh
# Should print JSON with hookSpecificOutput.additionalContext and remove the
# sentinel. A second run should print nothing.

set -euo pipefail

SENTINEL="$HOME/.claude/.post-compact-pending"

# No compaction since the last injection: stay silent.
if [ ! -f "$SENTINEL" ]; then
  exit 0
fi

# Clear first. If the emit below fails, the rules are missed once rather than
# repeated on every prompt for the rest of the session.
rm -f "$SENTINEL" 2>/dev/null || true

# The rules that must survive compaction, in priority order. These are the
# rules most likely to be violated after compaction because they constrain
# output style and process, not just code.
CTX=$(cat <<'RULES'
## Critical rules (re-injected after compaction, do not discard)

1. Named exports only. Never export default (except Next.js App Router convention files and Storybook).
2. Sort sibling keys deterministically where order is semantically free (default alphabetical); never reorder where position carries meaning (R-323).
3. One commit per task. Never accumulate across tasks (R-504).
4. Check for a parallel session before the first edit; active parallel session means move to a worktree (R-501). Never push main without express request (R-514).
5. Model routing: Sonnet default, Opus for complex/security/ambiguous, Haiku for trivial.
6. Never deploy without explicit user sign-off. Staging first, then ask before production.
7. CSRF: X-Requested-With header pattern. No token endpoint.
8. Shared code publishes under the project-agnostic @repo/* scope (R-301): @repo/types, @repo/constants.
9. No praise without falsifiable reasoning. No softening. No compliment sandwich.
10. No filler. Delete before sending: action announcements, question echoes, transitions, hedges, sign-offs, apologies, trailing summaries, "I" sentences.
11. Write rules for the model. Omit rationale and motivation. State imperatives. (R-206)
12. When user asserts something exists, investigate before disputing. Never treat context absence as evidence of absence. (R-205)
RULES
)

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'

exit 0
