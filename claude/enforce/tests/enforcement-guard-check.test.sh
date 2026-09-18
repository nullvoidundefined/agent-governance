#!/usr/bin/env bash
# Covers: hook:enforcement-guard-check
# Verifies enforcement-guard-check.sh is silent when every manifest-required hook is
# registered, and warns (naming the hook) when one is missing.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/enforcement-guard-check.sh"

# Case 1: real settings + manifest -> silent. CLAUDE_JUDGE_CMD isolates this
# case from judge-tier liveness (covered by case 6), which depends on whether
# the running environment carries an API key.
OUT=$(CLAUDE_JUDGE_CMD=stub "$HOOK" < /dev/null)
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

# Case 6 (2026-07-31 criticism audit P0): llm-judge rules with no key and no
# stub in the environment -> warn about the inert judge tier; the acceptance
# marker silences it as a recorded deliberate choice.
# A bogus keychain service isolates the test from any real keychain entry.
NOACCEPT=$(mktemp -d)/absent
OUT6=$(env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" CLAUDE_JUDGE_ACCEPT_FILE="$NOACCEPT" "$HOOK" < /dev/null)
grep -q "llm-judge tier" <<< "$OUT6" || { echo "FAIL: expected inert-judge warning"; exit 1; }
ACCEPT=$(mktemp)
OUT7=$(env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" CLAUDE_JUDGE_ACCEPT_FILE="$ACCEPT" "$HOOK" < /dev/null)
grep -q "llm-judge tier" <<< "$OUT7" && { echo "FAIL: acceptance marker should silence the warning"; exit 1; } || true

# Case 7 (2026-09-17 audit P3-7): the key probe reads every supported secret
# store, not the macOS keychain alone. A Linux host could not clear this
# warning the way its own message described, because `security` does not exist
# there. Each store is stubbed on PATH in turn; a stub that fails must leave
# the warning standing, so the probe cannot be satisfied by mere presence.
for store in secret-tool pass; do
  STUB_DIR=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/$store"
  chmod +x "$STUB_DIR/$store"
  OUT8=$(env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD PATH="$STUB_DIR:$PATH" \
    CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" \
    CLAUDE_JUDGE_ACCEPT_FILE="$NOACCEPT" "$HOOK" < /dev/null)
  grep -q "llm-judge tier" <<< "$OUT8" \
    && { echo "FAIL: a key found via $store must silence the inert-judge warning"; exit 1; } || true

  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/$store"
  OUT9=$(env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD PATH="$STUB_DIR:$PATH" \
    CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" \
    CLAUDE_JUDGE_ACCEPT_FILE="$NOACCEPT" "$HOOK" < /dev/null)
  grep -q "llm-judge tier" <<< "$OUT9" \
    || { echo "FAIL: $store present but holding no key must still warn"; exit 1; }
  rm -rf "$STUB_DIR"
done

# The warning names a command the host can actually run.
grep -q "secret-tool store" <<< "$OUT6" \
  || { echo "FAIL: the warning must name the Linux provisioning command too"; exit 1; }

echo "enforcement-guard-check.test.sh PASS"
