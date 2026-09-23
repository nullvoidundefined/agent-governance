#!/usr/bin/env bash
# handoff-check.sh: PostToolUse(Write) reminder for R-602 (2026-09-17 skills
# audit, S-5). session-start.sh SHA-verifies a handoff only when the next
# session loads it, one session too late to fix a wrong SHA, and nothing
# checked the size cap or the section order at all. When the written file is
# docs/session-handoff/session-handoff.md this reminds, naming each miss:
#   - over 8 KB (R-602's cap), measured over the NARRATIVE only: the
#     marker-delimited task-state block that session-end.sh generates is
#     excluded first, because R-602 places that generated block outside the
#     budget and nobody writing a handoff controls how large it grows;
#   - a missing or out-of-order section; the six, in order, are last commit,
#     production state, session metrics, what shipped, pending, next session
#     (matched case-insensitively against the "## " headings, so numbering
#     and wording around the keywords are free);
#   - no commit SHA in backticks, or one that does not resolve in the
#     repository the file lives in (session-start.sh applies the same test).
#
# Since IAN-260 it reads two kinds under docs/session-handoff/: the index
# (session-handoff.md), which keeps every check above, and a session file
# (YYYY-MM-DD-<slug>.md, an immediate child), which keeps the sections and
# the SHA but carries no cap, because exactly one session writes it so there
# is nothing for a cap to protect. Silent for every other path. Never blocks; any internal fault exits 0 so
# the hook can never break a Write. Advisory, so no `set -e` (enforce/README,
# hook set convention).
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
# Two kinds of handoff live under docs/session-handoff/ (IAN-260):
#
#   KIND=index    session-handoff.md, the one file session-start.sh loads.
#                 Rewritten every session, so it is the contended one and it
#                 carries the cap. It also owes a `## Sessions` list, which is
#                 the only route from the index to the per-session files.
#   KIND=session  YYYY-MM-DD-<slug>.md, written by exactly one session.
#                 Same six sections, no cap: nothing else writes it, so there
#                 is nothing for a cap to protect, and the cap is what forced
#                 four sessions to be folded by hand and lost content twice.
#
# Anything else is silent, including a dated file outside this directory and
# an undated file inside it (a README, an index of indexes), because applying
# handoff rules to a document that is not one is noise.
KIND=""
case "$FILE" in
  */docs/session-handoff/session-handoff.md|docs/session-handoff/session-handoff.md) KIND="index" ;;
  *)
    # The parent must END at docs/session-handoff: `*` in a case pattern
    # matches `/` too, so a single `*/docs/session-handoff/*` also swallows
    # docs/session-handoff/deeper/2026-09-20-x.md at any depth, and would
    # apply handoff rules to a document that is not one. Comparing the parent
    # exactly keeps session files immediate children, as the spec says.
    BASENAME="${FILE##*/}"
    PARENT="${FILE%/*}"
    case "$PARENT" in
      */docs/session-handoff|docs/session-handoff)
        # `?*` after the final hyphen requires a non-empty slug, so
        # `2026-09-20-.md` is not a session file.
        case "$BASENAME" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-?*.md) KIND="session" ;;
        esac
        ;;
    esac
    ;;
esac
[ -n "$KIND" ] || exit 0
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || true)
[ -n "$CONTENT" ] || exit 0

MAX_BYTES=8192
missing=()

# narrative_without_task_state prints handoff content $1 with the generated
# <!-- task-state:begin --> / <!-- task-state:end --> block removed, the
# marker lines themselves included. R-602 caps the NARRATIVE at 8 KB, and
# session-end.sh's render_task_state_section appends a task list it
# generates itself, whose size is a function of how many tasks the session
# touched rather than of anything the author wrote. Measuring the whole file
# therefore reported a cap violation against a perfectly compliant narrative
# as soon as that block grew, and the only way to silence it was to cut real
# narrative (PR #14 review). Matching is on the literal marker lines only,
# exactly as the renderer writes and replaces them, so a fenced code block
# quoting an example "## Task state" heading is never stripped.
narrative_without_task_state() {
  printf '%s' "$1" | awk '
    BEGIN { skipping = 0 }
    /^<!-- task-state:begin -->[[:space:]]*$/ { skipping = 1; next }
    /^<!-- task-state:end -->[[:space:]]*$/ { if (skipping) { skipping = 0; next } }
    skipping { next }
    { print }
  '
}

# The cap is the index's alone. A session file is uncontended, so measuring it
# buys nothing and costs the detail the next session needs (IAN-260).
if [ "$KIND" = "index" ]; then
  NARRATIVE=$(narrative_without_task_state "$CONTENT")
  bytes=$(printf '%s' "$NARRATIVE" | wc -c | tr -d ' ')
  [ "$bytes" -le "$MAX_BYTES" ] || missing+=("it is $bytes bytes, over the 8 KB cap; move detail into a session file, do not cut sections")
fi

# The index also owes a `## Sessions` list, without which it stops being a
# route to the session files. That check is deliberately NOT here yet: it
# would make today's index non-compliant, and no session file exists for it
# to list until the migration slice writes them. It lands with that slice,
# together with the update to handoff-check.test.sh's compliant fixture.

HEADINGS=$(printf '%s\n' "$CONTENT" | grep -E '^## ' | tr '[:upper:]' '[:lower:]' || true)
EXPECTED=("last commit" "production state" "session metrics" "what shipped" "pending" "next session")
last_index=0
absent=()
disordered=()
for key in "${EXPECTED[@]}"; do
  index=$(printf '%s\n' "$HEADINGS" | grep -n -F "$key" | head -1 | cut -d: -f1 || true)
  if [ -z "$index" ]; then
    absent+=("$key")
  elif [ "$index" -lt "$last_index" ]; then
    disordered+=("$key")
  else
    last_index="$index"
  fi
done
[ "${#absent[@]}" -eq 0 ] || missing+=("no section for: $(IFS=', '; echo "${absent[*]}")")
[ "${#disordered[@]}" -eq 0 ] || missing+=("out of order: $(IFS=', '; echo "${disordered[*]}") (the fixed order is last commit, production state, session metrics, what shipped, pending, next session)")

SHA=$(printf '%s' "$CONTENT" | grep -oE '`[0-9a-f]{7,40}`' | head -1 | tr -d '`' || true)
if [ -z "$SHA" ]; then
  missing+=("no commit SHA in backticks under the last-commit section (session-start.sh verifies it before trusting the file)")
else
  DIR=$(dirname "$FILE")
  [ -d "$DIR" ] || DIR=.
  if ! git -C "$DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
    missing+=("the recorded SHA $SHA does not resolve in this repository; the next session will load the handoff as UNVERIFIED")
  fi
fi

[ "${#missing[@]}" -gt 0 ] || exit 0
MSG="Handoff $FILE does not meet R-602: $(IFS='; '; echo "${missing[*]}"). The section order and the cap are in rulebook/reference.md under R-602; hooks/session-metrics.sh prints the metrics block."
jq -n --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null || true
exit 0
