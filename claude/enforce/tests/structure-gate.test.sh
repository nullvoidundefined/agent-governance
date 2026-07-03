#!/usr/bin/env bash
# Verifies structure-gate.sh denies banned/kebab source dirs and allows camelCase + app routes.
set -euo pipefail
HOOK="$HOME/.claude/hooks/structure-gate.sh"
deny() { printf '%s' "$1" | "$HOOK" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; }
allow() { [ -z "$(printf '%s' "$1" | "$HOOK")" ]; }
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/user-preferences/index.ts"}}'   # kebab (R-312)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/user_preferences/index.ts"}}'   # snake (R-312)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/utils/format.ts"}}'             # banned (R-306)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/lib/format.ts"}}'               # banned, 2nd name
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/app/utils/page.tsx"}}'          # banned beats app exemption
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/kebab-dir/app/coming-soon/page.tsx"}}'  # kebab BEFORE app still denied
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/userPreferences/index.ts"}}'   # camelCase ok
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/app/coming-soon/page.tsx"}}'   # app route segment exempt
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/db/pool.ts"}}'                   # abbreviated (R-311)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/di/container.ts"}}'              # abbreviated (R-311)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/svc/user.ts"}}'                  # abbreviated (R-311)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/ctrl/user.ts"}}'                 # abbreviated (R-311)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/mw/auth.ts"}}'                   # abbreviated (R-311)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/cfg/index.ts"}}'                 # abbreviated (R-311)
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/database/pool.ts"}}'            # full word ok
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/dependencyInjection/container.ts"}}'  # full word ok
echo "structure-gate.test.sh PASS"
