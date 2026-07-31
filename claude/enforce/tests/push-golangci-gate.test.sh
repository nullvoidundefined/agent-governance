#!/usr/bin/env bash
# Verifies push-golangci-gate.sh denies a push whose outgoing diff adds a Go
# AST-tier violation, scopes to added lines, and fails open on unparseable
# output. golangci-lint is stubbed via CLAUDE_GOLANGCI_CMD (canned JSON), so
# the test exercises the gate's diff/filter/deny logic without a local install.
set -euo pipefail
HOOK="$HOME/.claude/hooks/push-golangci-gate.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init

mkstub() { local j f; j=$(mktemp); printf '%s' "$1" > "$j"; f=$(mktemp); printf '#!/usr/bin/env bash\ncat %q\n' "$j" > "$f"; chmod +x "$f"; echo "$f"; }

# Violation on an added line -> deny.
mkdir -p internal/services
printf 'package services\n\nfunc IsExpired(age int) bool {\n\treturn age > 86400\n}\n' > internal/services/ttl.go
git add .; git commit -q -m "chore: bad"
S1=$(mkstub '{"Issues":[{"FromLinter":"mnd","Text":"Magic number: 86400","Pos":{"Filename":"internal/services/ttl.go","Line":4}}]}')
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_GOLANGCI_CMD="$S1" "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# Violation reported on a line the diff did NOT add -> allow (added-only scoping).
printf 'package services\n\nfunc IsExpired(age int) bool {\n\treturn age > 86400\n}\n\nfunc IsFresh(age int) bool {\n\treturn !IsExpired(age)\n}\n' > internal/services/ttl.go
git add .; git commit -q -m "chore: clean-addition"
S2=$(mkstub '{"Issues":[{"FromLinter":"mnd","Text":"Magic number: 86400","Pos":{"Filename":"internal/services/ttl.go","Line":4}}]}')
OUT2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_GOLANGCI_CMD="$S2" "$HOOK")
[ -z "$OUT2" ]

# No issues -> allow.
S3=$(mkstub '{"Issues":[]}')
OUT3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_GOLANGCI_CMD="$S3" "$HOOK")
[ -z "$OUT3" ]

# Unparseable output (both flag attempts) -> fail open (allow).
S4=$(mkstub 'golangci exploded')
OUT4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_GOLANGCI_CMD="$S4" "$HOOK" 2>/dev/null)
[ -z "$OUT4" ]

echo "push-golangci-gate.test.sh PASS"
