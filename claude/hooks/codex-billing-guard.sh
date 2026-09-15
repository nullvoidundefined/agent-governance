#!/usr/bin/env bash
# codex-billing-guard.sh: PreToolUse(Bash) hook backing R-908. R-907 dispatches
# test-writing to the `codex` CLI under the ChatGPT subscription; this warns
# before any `codex` invocation that would instead bill the metered OpenAI API,
# so that switch never happens silently. Two things flip billing: an
# OPENAI_API_KEY the codex CLI can see (inline in the command, exported earlier
# in the same command, or already present in the calling environment) and a
# `codex login --with-api-key`/`--with-access-token` re-auth. Absent either,
# the live `codex login status` is the authority. Asks, never blocks: API
# billing may be a deliberate choice, but never an accidental one.
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# Only commands that actually invoke the codex CLI matter here.
printf '%s' "$cmd" | grep -Eq '(^|[;&|(]|[[:space:]])codex([[:space:]]|$)' || exit 0

emit() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

if printf '%s' "$cmd" | grep -Eq 'codex login[^;&|]*--with-(api-key|access-token)'; then
  emit "codex-billing-guard: this command runs 'codex login --with-api-key' or '--with-access-token', switching the codex CLI from the ChatGPT subscription to metered API billing (R-908). Confirm this is deliberate."
fi

if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])(export[[:space:]]+)?OPENAI_API_KEY='; then
  emit "codex-billing-guard: this command sets OPENAI_API_KEY, which the codex CLI prefers over the stored ChatGPT login and switches usage to metered API billing (R-908). Confirm this is deliberate, or drop it to stay on the subscription."
fi

if [ -n "${OPENAI_API_KEY:-}" ]; then
  emit "codex-billing-guard: OPENAI_API_KEY is set in the environment this command inherits, which the codex CLI prefers over the stored ChatGPT login and switches usage to metered API billing (R-908). Confirm this is deliberate, or unset OPENAI_API_KEY to stay on the subscription."
fi

status="$(${CLAUDE_CODEX_CMD:-codex} login status 2>&1 || true)"
if ! printf '%s' "$status" | grep -qi 'Logged in using ChatGPT'; then
  emit "codex-billing-guard: 'codex login status' does not report ChatGPT auth (got: '${status:-empty}'). Running codex now likely bills the OpenAI API instead of the ChatGPT subscription (R-908). Confirm before proceeding, or run 'codex login' to reauthenticate with ChatGPT."
fi

exit 0
