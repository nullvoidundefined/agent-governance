#!/usr/bin/env bash
# Shard: fast
# Covers: hook:mcp-action-guard
# Exercise the real adapter's single-use MCP approval lifecycle. Synthetic hook
# events prove the adapter contract, not authenticity of a desktop runtime event.
set -euo pipefail

REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
ADAPTER="$REPO_TOP/codex/hooks/codex-hook-adapter.sh"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/codex-approval-state.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
FIXTURE_HOME="$SANDBOX/home"
FIXTURE_CLAUDE="$FIXTURE_HOME/.claude"
WORK="$SANDBOX/work"
mkdir -p "$FIXTURE_CLAUDE/hooks" "$FIXTURE_CLAUDE/enforce" "$WORK"
cp "$REPO_TOP/claude/enforce/settings-permission-rules.sh" "$FIXTURE_CLAUDE/enforce/"
printf '{"permissions":{"allow":[],"deny":[],"ask":[]}}\n' > "$FIXTURE_CLAUDE/settings.json"

# This hook always asks. Approval must be resolved by the real adapter, and
# every retry must still execute the hook rather than skipping its decision.
cat > "$FIXTURE_CLAUDE/hooks/fixture-consent.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf 'visited\n' >> "$HOME/hook-visits"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Approve this exact fixture PR body."}}\n'
HOOK
chmod +x "$FIXTURE_CLAUDE/hooks/fixture-consent.sh"

# All persistent state is contained by the temporary HOME. Do not supply an
# approval policy override: the default must support scoped, explicit consent.
run_event() {
  local payload="$1"
  shift
  printf '%s' "$payload" | env -u CLAUDE_CODEX_ASK_POLICY \
    -u CLAUDE_CODEX_STATE_DIR -u CLAUDE_HOOKS_DIR -u CLAUDE_ENFORCE_DIR \
    -u CLAUDE_PERMISSION_RULES_FILE \
    HOME="$FIXTURE_HOME" CLAUDE_HOME="$FIXTURE_CLAUDE" \
    CLAUDE_SETTINGS_FILE="$FIXTURE_CLAUDE/settings.json" \
    bash "$ADAPTER" "$@"
}

tool_event() {
  jq -nc --arg cwd "$WORK" --arg use "$1" --arg turn "$2" \
    '{hook_event_name:"PreToolUse",session_id:"fixture-session",turn_id:$turn,
      cwd:$cwd,tool_use_id:$use,tool_name:"mcp__github__update_pull_request",
      tool_input:{owner:"fixture",repo:"demo",pullNumber:7,body:"Reviewed body."}}'
}

assert_denied() {
  if ! printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny" or .decision == "block"' >/dev/null; then
    printf 'FAIL: %s\n' "$2"
    exit 1
  fi
  printf 'PASS: %s\n' "$2"
}

# A successful Codex hook may emit no JSON, or context without a deny decision.
# Non-JSON output and an explicit ask remain failures rather than consent.
assert_permitted() {
  if [ -n "$1" ] && ! printf '%s' "$1" | jq -e \
    '(.hookSpecificOutput.permissionDecision // "") as $decision |
      ($decision == "" or $decision == "allow") and (.decision // "") != "block"' >/dev/null; then
    printf 'FAIL: %s\n' "$2"
    exit 1
  fi
  printf 'PASS: %s\n' "$2"
}

initial_result=$(run_event "$(tool_event original original-turn)" fixture-consent)
assert_denied "$initial_result" 'an initial MCP ask is denied without user approval'

approval_event=$(jq -nc --arg cwd "$WORK" \
  '{hook_event_name:"UserPromptSubmit",session_id:"fixture-session",
    turn_id:"approval-turn",cwd:$cwd,prompt:"I approve"}')
run_event "$approval_event" >/dev/null

retry_result=$(run_event "$(tool_event approved-retry approval-turn)" fixture-consent)
assert_permitted "$retry_result" 'one identical MCP retry is permitted after explicit approval'

replay_result=$(run_event "$(tool_event repeated-retry approval-turn)" fixture-consent)
assert_denied "$replay_result" 'a consumed approval cannot permit a second retry'

if [ "$(wc -l < "$FIXTURE_HOME/hook-visits" | tr -d ' ')" != 3 ]; then
  printf 'FAIL: the asking hook must evaluate every tool attempt\n'
  exit 1
fi
printf 'PASS: the asking hook evaluates every tool attempt\n'
