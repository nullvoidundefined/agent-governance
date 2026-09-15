#!/usr/bin/env bash
# Verifies codex-billing-guard.sh (PreToolUse Bash, R-908): silent on
# non-codex commands, asks on every path that flips codex CLI billing from
# the ChatGPT subscription to the metered API, and silent when codex reports
# ChatGPT auth. codex login status is stubbed via CLAUDE_CODEX_CMD so the
# test does not depend on this machine's live login state.
set -euo pipefail
HOOK="$HOME/.claude/hooks/codex-billing-guard.sh"

mkstub() {
  local f
  f=$(mktemp)
  printf '#!/usr/bin/env bash\necho %q\n' "$1" > "$f"
  chmod +x "$f"
  echo "$f"
}

decision() {
  local out
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | env -u OPENAI_API_KEY CLAUDE_CODEX_CMD="$2" "$HOOK")
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

CHATGPT_STUB=$(mkstub "Logged in using ChatGPT")
APIKEY_STUB=$(mkstub "Logged in using an API key")

# A command that never mentions codex is none of this hook's business.
[ "$(decision 'ls -la' "$CHATGPT_STUB")" = "none" ] || { echo "FAIL: expected none for a non-codex command"; exit 1; }

# Plain codex invocation, ChatGPT-authenticated -> silent.
[ "$(decision 'codex exec "write tests"' "$CHATGPT_STUB")" = "none" ] || { echo "FAIL: expected none for a plain codex call under ChatGPT auth"; exit 1; }

# Re-authenticating with an API key or access token -> ask, caught before the
# login status check even runs.
[ "$(decision 'codex login --with-api-key' "$CHATGPT_STUB")" = "ask" ] || { echo "FAIL: expected ask for codex login --with-api-key"; exit 1; }
[ "$(decision 'codex login --with-access-token' "$CHATGPT_STUB")" = "ask" ] || { echo "FAIL: expected ask for codex login --with-access-token"; exit 1; }

# OPENAI_API_KEY set inline or exported in the same command -> ask.
[ "$(decision 'OPENAI_API_KEY=sk-x codex exec "hi"' "$CHATGPT_STUB")" = "ask" ] || { echo "FAIL: expected ask for inline OPENAI_API_KEY"; exit 1; }
[ "$(decision 'export OPENAI_API_KEY=sk-x; codex exec "hi"' "$CHATGPT_STUB")" = "ask" ] || { echo "FAIL: expected ask for exported OPENAI_API_KEY"; exit 1; }

# OPENAI_API_KEY already present in the inherited environment -> ask, even
# with no override in the command text itself.
OUT=$(jq -n --arg c 'codex exec "hi"' '{tool_name:"Bash",tool_input:{command:$c}}' | OPENAI_API_KEY=sk-x CLAUDE_CODEX_CMD="$CHATGPT_STUB" "$HOOK")
GOT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"')
[ "$GOT" = "ask" ] || { echo "FAIL: expected ask when OPENAI_API_KEY is already in the environment, got $GOT"; exit 1; }

# Live login status is not ChatGPT -> ask, naming what codex reported.
[ "$(decision 'codex exec "hi"' "$APIKEY_STUB")" = "ask" ] || { echo "FAIL: expected ask when codex login status is not ChatGPT"; exit 1; }

echo "codex-billing-guard.test.sh PASS"
