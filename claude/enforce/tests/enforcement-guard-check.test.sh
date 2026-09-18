#!/usr/bin/env bash
# Covers: hook:enforcement-guard-check
# Verifies enforcement-guard-check.sh is silent when every manifest-required hook is
# registered, and warns (naming the hook) when one is missing.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/enforcement-guard-check.sh"

# Case 1: real settings + manifest -> silent.
OUT=$("$HOOK" < /dev/null)
[ -z "$OUT" ] || { echo "FAIL: expected silent when all registered; got: $OUT"; exit 1; }

# Case 2: a settings file missing push-eslint-gate -> warns and names it.
FIX=$(mktemp)
jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("push-eslint-gate") | not))' \
  "$CLAUDE_HARNESS_ROOT/settings.json" > "$FIX"
OUT2=$(CLAUDE_SETTINGS_FILE="$FIX" "$HOOK" < /dev/null)
grep -q "push-eslint-gate" <<< "$OUT2" || { echo "FAIL: expected warning naming push-eslint-gate"; exit 1; }

# Case 3 (reverse direction, P2-1): a manifest missing an enforcer the rule
# files cite in an Enforcement line -> warns naming the enforcer.
FIX2=$(mktemp)
jq '.rules |= map(select(.enforcer != "hook:no-em-dash"))' "$CLAUDE_HARNESS_ROOT/enforce/manifest.json" > "$FIX2"
OUT3=$(CLAUDE_MANIFEST_FILE="$FIX2" "$HOOK" < /dev/null)
grep -q "hook:no-em-dash" <<< "$OUT3" || { echo "FAIL: expected warning naming hook:no-em-dash as cited-but-unmapped"; exit 1; }

# Case 4 (2026-07-31 audit P1): ruff:* manifest entries require push-ruff-gate
# registration; a settings file without it must warn and name the gate.
FIX3=$(mktemp)
jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("push-ruff-gate") | not))' \
  "$CLAUDE_HARNESS_ROOT/settings.json" > "$FIX3"
OUT4=$(CLAUDE_SETTINGS_FILE="$FIX3" "$HOOK" < /dev/null)
grep -q "push-ruff-gate" <<< "$OUT4" || { echo "FAIL: expected warning naming push-ruff-gate"; exit 1; }

# Case 5: same guarantee for the Ruby and Go tiers.
FIX4=$(mktemp)
jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("push-rubocop-gate|push-golangci-gate") | not))' \
  "$CLAUDE_HARNESS_ROOT/settings.json" > "$FIX4"
OUT5=$(CLAUDE_SETTINGS_FILE="$FIX4" "$HOOK" < /dev/null)
grep -q "push-rubocop-gate" <<< "$OUT5" || { echo "FAIL: expected warning naming push-rubocop-gate"; exit 1; }
grep -q "push-golangci-gate" <<< "$OUT5" || { echo "FAIL: expected warning naming push-golangci-gate"; exit 1; }

# Case 6 (2026-09-18, IAN-98): the llm-judge tier runs in CI
# (.github/workflows/rule-judge.yml) against a repository secret, so a host
# with no local key is not a degraded judge and must not be told to provision
# one. The former inert-judge warning (2026-07-31 criticism audit P0) and its
# key-store probes (2026-09-17 audit P3-7) went with the push hook.
NOACCEPT=$(mktemp -d)/absent
OUT6=$(env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" CLAUDE_JUDGE_ACCEPT_FILE="$NOACCEPT" "$HOOK" < /dev/null)
grep -q "llm-judge tier" <<< "$OUT6" && { echo "FAIL: a missing local key must not warn now that the judge runs in CI; got: $OUT6"; exit 1; }
[ -z "$OUT6" ] || { echo "FAIL: expected silence with no local key; got: $OUT6"; exit 1; }

echo "enforcement-guard-check.test.sh PASS"
