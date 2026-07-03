#!/usr/bin/env bash
# PostToolUse(Write) hook: nudge toward domain subfolders when a directory goes
# over-flat (R-310).
#
# Runs after a Write lands (so disk reflects the final tree) and counts the
# source modules sitting directly in the written file's parent directory. When
# the count exceeds the threshold it emits a non-blocking reminder
# (additionalContext) restating the R-310 regroup decision. Counts source
# modules only: top level of the directory (never recursive), excluding index
# barrels, sibling constants/types modules, tests, stories, and declarations.
# Silent at or below the threshold and for non-source writes. Never blocks; the
# threshold is a smell that forces a decision, not a hard fail, so a flat peer
# set with no domain seams (migrations, route segments) is a legitimate keep.
THRESHOLD=20

file_path=$(jq -rc '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

case "$file_path" in
    *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs) : ;;
    *) exit 0 ;;
esac
case "$file_path" in
    *.d.ts | *.test.* | *.spec.* | *__tests__* | *__fixtures__* | *.stories.* | *.config.* | */migrations/* | */node_modules/* | */dist/* | */.next/*) exit 0 ;;
esac

directory=$(dirname "$file_path")

count=$(find "$directory" -maxdepth 1 -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) \
    ! -name 'index.ts' ! -name 'index.tsx' ! -name 'constants.ts' ! -name 'types.ts' \
    ! -name '*.d.ts' ! -name '*.test.*' ! -name '*.spec.*' ! -name '*.stories.*' ! -name '*.config.*' \
    2>/dev/null | wc -l | tr -d ' ')

[ "$count" -gt "$THRESHOLD" ] || exit 0

jq -nc --arg dir "$directory" --arg count "$count" --arg threshold "$THRESHOLD" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Flat-directory check (R-310): " + $dir + " now holds " + $count + " source modules (over " + $threshold + "). Regroup into domain subfolders named for the responsibility they hold (camelCase), grouping by domain or operation, not by file type. Each new subfolder needs 2+ modules (no single-file folders, R-309). If the modules genuinely form one flat peer set with no domain seams, document why in the nearest CLAUDE.md and leave it flat. Non-blocking. No em dashes.")}}' 2>/dev/null || true
