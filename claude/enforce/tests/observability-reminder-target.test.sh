#!/usr/bin/env bash
# Covers: hook:observability-reminder
# Verifies the reminder observability-reminder.sh emits points at the file that
# holds the observability patterns. Three invariants:
#   1. A triggering write (an Express app.ts with routes and no /health) emits a
#      non-empty reminder, so a silent hook cannot pass the text checks.
#   2. The reminder names ~/.claude/CLAUDE-OBSERVABILITY.md and no longer points
#      at "CLAUDE-BACKEND.md under Observability".
#   3. The named file exists under the harness root and carries the heading
#      "### Observability (R-341 to R-346)", so the pointer leads to the patterns.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/observability-reminder.sh"
TARGET="$CLAUDE_HARNESS_ROOT/CLAUDE-OBSERVABILITY.md"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/apps/server/src"

run() { jq -n --arg f "$1" '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$HOOK"; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }

# 1. The reminder is emitted.
printf 'import express from "express";\nconst app = express();\napp.use(express.json());\napp.get("/notes", listNotes);\nexport { app };\n' > "$TMP/apps/server/src/app.ts"
OUT=$(run "$TMP/apps/server/src/app.ts")
MSG=$(ctx "$OUT")
[ -n "$MSG" ] || { echo "FAIL: expected a reminder for an app with routes and no /health, got nothing"; exit 1; }

# 2. The reminder points at the shared observability file, not the old backend section.
grep -qF '~/.claude/CLAUDE-OBSERVABILITY.md' <<< "$MSG" || { echo "FAIL: reminder must name ~/.claude/CLAUDE-OBSERVABILITY.md, got: $MSG"; exit 1; }
if grep -qF 'CLAUDE-BACKEND.md under Observability' <<< "$MSG"; then
  echo "FAIL: reminder still points at CLAUDE-BACKEND.md under Observability, got: $MSG"; exit 1
fi

# 3. The pointer leads to the patterns.
[ -f "$TARGET" ] || { echo "FAIL: $TARGET does not exist"; exit 1; }
grep -qF '### Observability (R-341 to R-346)' "$TARGET" || { echo "FAIL: $TARGET lacks the heading ### Observability (R-341 to R-346)"; exit 1; }

echo "observability-reminder-target.test.sh PASS"
