#!/usr/bin/env bash
# Verifies push-rubocop-gate.sh denies a push whose outgoing diff adds a Ruby
# AST-tier violation, scopes to added lines, and fails open on unparseable
# output. RuboCop is stubbed via CLAUDE_RUBOCOP_CMD (canned JSON), so the test
# exercises the gate's diff/filter/deny logic without a local RuboCop.
set -euo pipefail
HOOK="$HOME/.claude/hooks/push-rubocop-gate.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init

mkstub() { local j f; j=$(mktemp); printf '%s' "$1" > "$j"; f=$(mktemp); printf '#!/usr/bin/env bash\ncat %q\n' "$j" > "$f"; chmod +x "$f"; echo "$f"; }

# Violation on an added line -> deny.
mkdir -p app/models
printf "# frozen_string_literal: true\nclass Job\n  def status_label\n    a ? (b ? 1 : 2) : 3\n  end\nend\n" > app/models/job.rb
git add .; git commit -q -m "chore: bad"
S1=$(mkstub '{"files":[{"path":"app/models/job.rb","offenses":[{"severity":"convention","message":"Avoid nested ternary operators.","cop_name":"Style/NestedTernaryOperator","location":{"start_line":4,"line":4}}]}]}')
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_RUBOCOP_CMD="$S1" "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# Violation reported on a line the diff did NOT add -> allow (added-only scoping).
printf "# frozen_string_literal: true\nclass Job\n  def status_label\n    a ? (b ? 1 : 2) : 3\n  end\n\n  def fresh_label\n    'ok'\n  end\nend\n" > app/models/job.rb
git add .; git commit -q -m "chore: clean-addition"
S2=$(mkstub '{"files":[{"path":"app/models/job.rb","offenses":[{"severity":"convention","message":"Avoid nested ternary operators.","cop_name":"Style/NestedTernaryOperator","location":{"start_line":4,"line":4}}]}]}')
OUT2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_RUBOCOP_CMD="$S2" "$HOOK")
[ -z "$OUT2" ]

# No offenses -> allow.
S3=$(mkstub '{"files":[{"path":"app/models/job.rb","offenses":[]}]}')
OUT3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_RUBOCOP_CMD="$S3" "$HOOK")
[ -z "$OUT3" ]

# Unparseable output -> fail open (allow).
S4=$(mkstub 'rubocop exploded')
OUT4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_RUBOCOP_CMD="$S4" "$HOOK" 2>/dev/null)
[ -z "$OUT4" ]

echo "push-rubocop-gate.test.sh PASS"
