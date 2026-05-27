#!/usr/bin/env bash
# redact-output.sh
#
# PostToolUse hook for Bash. Scans command output for secret patterns and
# replaces them with [REDACTED] before the output reaches the model context.
#
# Uses suppressOutput to hide the raw output and additionalContext to inject
# the redacted version.

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
  # Perl handles the redaction with the pattern defined as a heredoc to
  # avoid shell interpolation issues
  REDACTED=$(printf '%s' "$RESPONSE" | perl -pe '
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
    s/re_[A-Za-z0-9_-]{30,}/[REDACTED]/g;
    s/rnd_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/xoxb-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/xoxp-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/xoxa-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/xoxs-[A-Za-z0-9-]{40,}/[REDACTED]/g;
    s/AKIA[0-9A-Z]{16}/[REDACTED]/g;
    s/ASIA[0-9A-Z]{16}/[REDACTED]/g;
    s/SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{40,}/[REDACTED]/g;
    s/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED]/g;
    s/AIza[0-9A-Za-z_-]{35}/[REDACTED]/g;
    s{postgres(?:ql)?://[^:]+:[^@]{8,}@\S+}{[REDACTED]}g;
    s/(SECRET|TOKEN|PASSWORD|CREDENTIAL|API[_-]?KEY|SECRET[_-]?KEY|ACCESS[_-]?KEY|AUTH[_-]?KEY|PRIVATE[_-]?KEY)[=:]\s*[A-Za-z0-9_\/+=~.-]{20,}/$1=[REDACTED]/g;
  ')

  jq -n --arg redacted "$REDACTED" '{
    suppressOutput: true,
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("[SECRET REDACTED] The command output contained secret values that were automatically redacted.\n\n" + $redacted)
    }
  }'
fi

exit 0
