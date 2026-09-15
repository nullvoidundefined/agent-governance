#!/usr/bin/env bash
# Verifies settings-change-guard.sh (ConfigChange, R-516). Four invariants:
#   1. The live settings.json, which registers every manifest-required hook, passes.
#   2. A copy that drops a required hook is blocked, naming the hook.
#   3. A non-user source is ignored even when the file is broken.
#   4. A file that does not parse is blocked.
set -euo pipefail
HOOK="$HOME/.claude/hooks/settings-change-guard.sh"
LIVE="$HOME/.claude/settings.json"
TMP=$(mktemp -d)

run() { jq -n --arg s "$1" --arg f "$2" '{hook_event_name:"ConfigChange",source:$s,file_path:$f}' | CLAUDE_FIRE_LOG=/dev/null "$HOOK" 2>/dev/null; }

# 1. Live settings pass.
OUT=$(run user_settings "$LIVE")
[ -z "$OUT" ] || { echo "FAIL: live settings.json was blocked: $OUT"; exit 1; }

# 2. Dropping git-workflow-guard is blocked and named.
jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("git-workflow-guard") | not))' "$LIVE" > "$TMP/dropped.json"
OUT=$(run user_settings "$TMP/dropped.json")
printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null || { echo "FAIL: expected a block when a required hook is dropped, got: $OUT"; exit 1; }
printf '%s' "$OUT" | grep -q 'git-workflow-guard.sh' || { echo "FAIL: block must name the dropped hook, got: $OUT"; exit 1; }

# 3. Other sources are ignored.
OUT=$(run project_settings "$TMP/dropped.json")
[ -z "$OUT" ] || { echo "FAIL: project_settings must not be judged, got: $OUT"; exit 1; }

# 4. Unparseable user settings are blocked.
printf '{ "permissions": { "allow": ["Bash"], }\n' > "$TMP/broken.json"
OUT=$(run user_settings "$TMP/broken.json")
printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null || { echo "FAIL: expected a block on unparseable settings, got: $OUT"; exit 1; }

echo "settings-change-guard.test.sh PASS"
