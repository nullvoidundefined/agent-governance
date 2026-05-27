#!/usr/bin/env bash
# pre-compact.sh
#
# PreCompact hook for Claude Code. Injects the most critical rules into
# the compaction context so they survive context window compression.
# Without this, compaction can lose rules that were loaded early in the
# session, causing drift in later turns.

set -euo pipefail

# The rules that must survive compaction, in priority order.
# These are the rules most likely to be violated after compaction
# because they constrain output style and process, not just code.
CTX=$(cat <<'RULES'
## Critical rules (injected by PreCompact hook, do not discard)

1. Named exports only. Never export default (except Next.js App Router convention files and Storybook).
2. Alphabetical ordering is mandatory for type definitions, keys, props, imports.
3. One commit per task. Never accumulate across tasks.
4. Worktree per task. Never work directly on main.
5. Model routing: Sonnet default, Opus for complex/security/ambiguous, Haiku for trivial.
6. Never deploy without explicit user sign-off. Staging first, then ask before production.
7. CSRF: X-Requested-With header pattern. No token endpoint.
8. Shared types in packages/types/, shared constants in packages/constants/.
9. No praise without falsifiable reasoning. No softening. No compliment sandwich.
10. No filler. Delete before sending: action announcements, question echoes, transitions, hedges, sign-offs, apologies, trailing summaries, "I" sentences.
11. Write rules for the model. Omit rationale and motivation. State imperatives. (R-512)
12. When user asserts something exists, investigate before disputing. Never treat context absence as evidence of absence. (R-513)
RULES
)

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "PreCompact",
    additionalContext: $ctx
  }
}'

exit 0
