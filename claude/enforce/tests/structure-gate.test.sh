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
# R-313/R-314 test placement
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/handlers/auth.test.ts"}}'            # co-located (R-313)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/services/test_match.py"}}'           # co-located python (R-313)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/handlers/__tests__/auth.test.ts"}}'  # per-dir nest (R-314)
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/__tests__/handlers/auth.test.ts"}}' # top-level tree ok
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/e2e/login.spec.ts"}}'                   # e2e specs ok
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/tests/test_auth.py"}}'                  # python tests/ ok
# Python tree exceptions: snake_case package dirs, blessed db/ and core/ (CLAUDE-PYTHON.md)
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/user_preferences/api.py"}}'         # snake ok for python (R-312 exception)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/user-preferences/api.py"}}'          # kebab still denied for python
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/db/engine.py"}}'                    # db/ blessed for python
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/core/config.py"}}'                  # core/ blessed for python
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/svc/user.py"}}'                      # other abbrevs still denied for python
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/src/utils/format.py"}}'                  # catch-alls still denied for python
# Python app/ root (CLAUDE-PYTHON.md layout): the gate must fire without a src/ segment
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/app/utils/format.py"}}'                  # catch-all under app/ root
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/app/svc/user.py"}}'                      # abbrev under app/ root
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/app/user-preferences/api.py"}}'          # kebab under app/ root
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/app/user_preferences/api.py"}}'         # snake ok under app/ root
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/app/db/engine.py"}}'                    # db/ blessed under app/ root
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/app/core/config.py"}}'                  # core/ blessed under app/ root
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/app/services/jobs/score_match.py"}}'    # canonical layout ok
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/app/utils/Format.tsx"}}'                # TS under app/ without src/ stays unscanned
# Ruby app/ and lib/ roots (CLAUDE-RUBY.md layout)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/app/utils/format.rb"}}'                  # catch-all under ruby app/
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/lib/helpers/format.rb"}}'                # catch-all under ruby lib/
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/app/svc/user.rb"}}'                      # abbrev under ruby app/
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/app/user-preferences/api.rb"}}'          # kebab denied for ruby
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/app/services/jobs/score_match.rb"}}'    # snake ok for ruby
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/lib/tasks/backfill_scores.rb"}}'        # lib/ blessed root for ruby
# Go internal/, cmd/, pkg/ roots (CLAUDE-GO.md layout)
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/internal/utils/format.go"}}'             # catch-all under go internal/
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/internal/helpers/format.go"}}'           # catch-all, 2nd name
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/internal/db/pool.go"}}'                 # db blessed for go
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/cmd/job-scorer/main.go"}}'              # kebab binary name ok for go
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/internal/services/score_match.go"}}'    # snake filename ok for go
# Ruby spec placement (R-313) and Go co-location exception
deny '{"tool_name":"Write","tool_input":{"file_path":"/x/app/models/job_spec.rb"}}'               # co-located spec denied
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/spec/models/job_spec.rb"}}'             # spec/ tree ok
allow '{"tool_name":"Write","tool_input":{"file_path":"/x/internal/services/score_match_test.go"}}'  # co-located _test.go REQUIRED for go

# R-306 applies to *creating* a catch-all, not writing into one that already exists.
BANNED_FIXTURE=$(mktemp -d)
mkdir -p "$BANNED_FIXTURE/src/shared/components"
allow "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BANNED_FIXTURE/src/shared/components/Widget.tsx\"}}"   # pre-existing shared/ ok
deny  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BANNED_FIXTURE/src/brandNew/shared/Widget.tsx\"}}"     # would create shared/
rm -rf "$BANNED_FIXTURE"

# R-313 co-location exemption is scoped to repos named in colocated-test-repos.txt.
COLOCATED_FIXTURE=$(mktemp -d)
ALLOWLIST="$HOME/.claude/enforce/colocated-test-repos.txt"
ALLOWLIST_BACKUP=$(mktemp)
cp "$ALLOWLIST" "$ALLOWLIST_BACKUP" 2>/dev/null || : >"$ALLOWLIST_BACKUP"
printf '%s\n' "$COLOCATED_FIXTURE" >>"$ALLOWLIST"
allow "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$COLOCATED_FIXTURE/src/handlers/auth.test.ts\"}}"       # exempt repo
deny  '{"tool_name":"Write","tool_input":{"file_path":"/x/src/handlers/other.test.ts"}}'                                # non-exempt repo still denied
cp "$ALLOWLIST_BACKUP" "$ALLOWLIST"
rm -rf "$COLOCATED_FIXTURE" "$ALLOWLIST_BACKUP"

echo "structure-gate.test.sh PASS"
