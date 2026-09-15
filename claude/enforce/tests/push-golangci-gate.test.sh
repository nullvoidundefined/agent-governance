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

# Trust gate (2026-07-31 security audit P0): with a real-looking golangci-lint
# on PATH and NO explicit override, an untrusted repo (origin not in
# gate-trusted-repos.txt) must skip without running the binary.
FAKEBIN=$(mktemp -d)
printf '#!/usr/bin/env bash\ntouch "%s/RAN"\necho "{}"\n' "$FAKEBIN" > "$FAKEBIN/golangci-lint"
chmod +x "$FAKEBIN/golangci-lint"
git remote add origin https://example.com/untrusted/repo.git 2>/dev/null || true
ERR5=$(printf '%s' "$PAYLOAD" | PATH="$FAKEBIN:$PATH" CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>&1 1>/dev/null)
printf '%s' "$ERR5" | grep -q "gate-trusted-repos" || { echo "FAIL: expected trust-skip note for untrusted repo"; exit 1; }
[ ! -f "$FAKEBIN/RAN" ] || { echo "FAIL: golangci binary ran against an untrusted repo"; exit 1; }

# The stub above proves the gate's parsing, not the config. A v1-schema config
# was rejected outright by v2 binaries and the gate failed open, so the Go
# gate enforced nothing (ISSUES.md P3, closed 2026-09-04). When the real binary
# is on PATH, the bundled config must verify against it.
# `config verify` needs the JSON schema from golangci-lint.run, so it is not
# an offline check; `linters --config` parses the file locally and lists what
# it enables, which is the fact that matters.
if command -v golangci-lint >/dev/null 2>&1; then
  ENABLED=$(golangci-lint linters --config "$HOME/.claude/enforce/golangci-enforce.yml" 2>&1 \
    | awk '/^Enabled by your configuration linters:/{on=1; next} /^Disabled by your configuration linters:/{on=0} on && /^[a-z0-9]+:/{sub(":.*",""); print}') \
    || { echo "FAIL: golangci-lint could not load enforce/golangci-enforce.yml ($(golangci-lint --version 2>/dev/null | head -1))"; exit 1; }
  for linter in errcheck errorlint mnd nolintlint; do
    printf '%s\n' "$ENABLED" | grep -qx "$linter" || { echo "FAIL: enforce/golangci-enforce.yml does not enable $linter (enabled: $(printf '%s' "$ENABLED" | tr '\n' ' '))"; exit 1; }
  done
fi

echo "push-golangci-gate.test.sh PASS"
