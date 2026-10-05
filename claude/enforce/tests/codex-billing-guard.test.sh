#!/usr/bin/env bash
# Covers: hook:codex-billing-guard
# Verifies codex-billing-guard.sh (PreToolUse Bash, R-908): silent on
# non-codex commands, asks on every path that flips codex CLI billing from
# the ChatGPT subscription to the metered API, and silent when codex reports
# ChatGPT auth. codex login status is stubbed via CLAUDE_CODEX_CMD so the
# test does not depend on this machine's live login state.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/codex-billing-guard.sh"

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

# Judge per simple command by parsed program, not by the word "codex" in the
# raw text. With a stub that reports NOT logged in to ChatGPT, any real codex
# invocation asks, so "none" proves the guard did not treat the command as one.
NOTLOGGED_STUB=$(mkstub "Not logged in")
NEWFAILS=0
expect() {
  local want="$1" cmd="$2" got
  got=$(decision "$cmd" "$NOTLOGGED_STUB")
  if [ "$got" != "$want" ]; then
    echo "FAIL: expected $want, got $got, for: $cmd"
    NEWFAILS=$((NEWFAILS + 1))
  fi
}

# Commands that only mention codex as an argument, path, or text -> none.
expect none 'git diff --numstat origin/main...HEAD -- codex cursor'
expect none 'ls codex/'
expect none 'node translate/codex.mjs --check'
expect none 'cat codex/AGENTS.md'
expect none 'grep -rn codex docs/'
expect none 'git log --oneline -- codex'
expect none 'echo codex'

# Real codex invocations, however launched -> still ask.
expect ask 'codex exec "write tests"'
expect ask "bash -c 'codex exec x'"
expect ask 'cd /tmp && codex exec x'
expect ask 'env FOO=1 codex exec x'
expect ask '/usr/local/bin/codex exec x'
expect ask 'npx codex exec x'

# Package-runner launches of the codex CLI -> ask.
expect ask 'npx @openai/codex exec x'
expect ask 'npx -y @openai/codex'
expect ask 'npx --yes @openai/codex exec'
expect ask 'pnpm dlx @openai/codex'
expect ask 'yarn dlx @openai/codex'
expect ask 'npm exec @openai/codex'
expect ask 'npx @openai/codex@latest exec'
expect ask 'npx -p @openai/codex codex exec'
expect ask 'yarn dlx -p @openai/codex codex'
expect ask 'npm exec --package @openai/codex -- codex'
expect ask 'pnpm exec codex'
expect ask 'npm --prefix x exec codex'
expect ask 'pnpm --silent dlx @openai/codex'
expect ask 'node ./node_modules/.bin/codex exec'

# Other tools and read-only mentions stay silent.
expect none 'npx @openai/other-tool'
expect none 'git diff -- codex'
expect none 'npm exec eslint'

[ "$NEWFAILS" -eq 0 ] || { echo "codex-billing-guard.test.sh: $NEWFAILS case(s) failed"; exit 1; }

echo "codex-billing-guard.test.sh PASS"
