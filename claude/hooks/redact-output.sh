#!/usr/bin/env bash
# redact-output.sh
#
# PostToolUse hook for Bash. Scans command output for secret patterns and,
# on a match, injects a redacted copy plus an exposure warning.
#
# HONEST SEMANTICS (2026-07-31 security audit P1): PostToolUse cannot rewrite
# or remove a tool result. suppressOutput hides only this hook's own stdout;
# the RAW output still reaches the model context and is written verbatim to
# the session transcript JSONL on disk. This hook is therefore detection and
# damage-control, not prevention: it tells the model a credential just leaked,
# to treat it as exposed, never repeat it, and recommend rotation. Prevention
# lives on the PreToolUse side (secret-scan.sh, the permissions lists).

set -euo pipefail

INPUT=$(cat)

# Extract the tool response content
RESPONSE=$(printf '%s' "$INPUT" | jq -r '
  if (.tool_response | type) == "string" then .tool_response
  elif (.tool_response.content | type) == "string" then .tool_response.content
  elif (.tool_response.stdout | type) == "string" then .tool_response.stdout
  else (.tool_response | tostring)
  end // ""
')

if [ -z "$RESPONSE" ]; then
  exit 0
fi

# Detect and redact using perl (avoids macOS sed limitations and shell
# interpolation issues). grep is used for fast detection; perl only runs
# when a match is found.
PATTERN='sk-ant-api03-[A-Za-z0-9_-]{50,}'
PATTERN+='|whsec_[A-Za-z0-9]{20,}'
PATTERN+='|sk_live_[A-Za-z0-9]{20,}'
PATTERN+='|sk_test_[A-Za-z0-9]{20,}'
PATTERN+='|rk_live_[A-Za-z0-9]{20,}'
PATTERN+='|rk_test_[A-Za-z0-9]{20,}'
PATTERN+='|ghp_[A-Za-z0-9]{30,}'
PATTERN+='|gho_[A-Za-z0-9]{30,}'
PATTERN+='|ghs_[A-Za-z0-9]{30,}'
PATTERN+='|ghu_[A-Za-z0-9]{30,}'
PATTERN+='|vcp_[A-Za-z0-9]{20,}'
PATTERN+='|re_[A-Za-z0-9_-]{30,}'
PATTERN+='|rnd_[A-Za-z0-9]{20,}'
PATTERN+='|xoxb-[A-Za-z0-9-]{40,}'
PATTERN+='|xoxp-[A-Za-z0-9-]{40,}'
PATTERN+='|xoxa-[A-Za-z0-9-]{40,}'
PATTERN+='|xoxs-[A-Za-z0-9-]{40,}'
PATTERN+='|AKIA[0-9A-Z]{16}'
PATTERN+='|ASIA[0-9A-Z]{16}'
PATTERN+='|SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{40,}'
PATTERN+='|-----BEGIN [A-Z ]*PRIVATE KEY-----'
PATTERN+='|AIza[0-9A-Za-z_-]{35}'
PATTERN+='|postgres(ql)?://[^:]+:[^@]{8,}@[^\s]+'
PATTERN+='|(SECRET|TOKEN|PASSWORD|CREDENTIAL|API[_-]?KEY|SECRET[_-]?KEY|ACCESS[_-]?KEY|AUTH[_-]?KEY|PRIVATE[_-]?KEY)[=:][[:space:]]*[A-Za-z0-9_/+=~.-]{20,}'

if printf '%s' "$RESPONSE" | grep -qE "$PATTERN"; then
  # Perl handles the redaction; -0777 slurps the whole response so the
  # private-key rule can span lines (the body, not just the BEGIN header).
  REDACTED=$(printf '%s' "$RESPONSE" | perl -0777 -pe '
    s/sk-ant-api03-[A-Za-z0-9_-]{50,}/[REDACTED]/g;
    s/whsec_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/sk_live_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/sk_test_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/rk_live_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/rk_test_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/ghp_[A-Za-z0-9]{30,}/[REDACTED]/g;
    s/gho_[A-Za-z0-9]{30,}/[REDACTED]/g;
    s/ghs_[A-Za-z0-9]{30,}/[REDACTED]/g;
    s/ghu_[A-Za-z0-9]{30,}/[REDACTED]/g;
    s/vcp_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/\bre_[A-Za-z0-9_-]{30,}/[REDACTED]/g;
    s/\brnd_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/xoxb-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/xoxp-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/xoxa-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/xoxs-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/AKIA[0-9A-Z]{16}/[REDACTED]/g;
    s/ASIA[0-9A-Z]{16}/[REDACTED]/g;
    s/SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{40,}/[REDACTED]/g;
    s/-----BEGIN ([A-Z ]*)PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/[REDACTED PRIVATE KEY]/gs;
    s/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED]/g;
    s/\bAIza[0-9A-Za-z_-]{35}/[REDACTED]/g;
    s{postgres(?:ql)?://[^:]+:[^@]{8,}@\S+}{[REDACTED]}g;
    s/(SECRET|TOKEN|PASSWORD|CREDENTIAL|API[_-]?KEY|SECRET[_-]?KEY|ACCESS[_-]?KEY|AUTH[_-]?KEY|PRIVATE[_-]?KEY)[=:]\s*[A-Za-z0-9_\/+=~.-]{20,}/$1=[REDACTED]/g;
  ')

  jq -n --arg redacted "$REDACTED" '{
    suppressOutput: true,
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("[SECRET DETECTED IN TOOL OUTPUT] The raw output above contains credential values, and it has ALREADY been written to the session transcript on disk; this hook cannot remove it. Treat every matched credential as exposed: (1) never repeat, echo, or write the raw values anywhere; (2) tell the user which credential leaked and recommend rotation plus a transcript purge; (3) use only this redacted copy for further reasoning:\n\n" + $redacted)
    }
  }'
fi

exit 0
