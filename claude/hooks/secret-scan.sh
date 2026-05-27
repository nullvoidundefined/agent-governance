#!/usr/bin/env bash
# secret-scan.sh
#
# PreToolUse hook for Claude Code Bash tool. Scans the command about to be
# executed for plaintext secret patterns and blocks the call if any match.
#
# Why this exists: On 2026-04-08, a plaintext Anthropic production key was
# passed on the command line via `railway variables --set ...`. The value
# leaked to shell history, the tool-call transcript, the permission prompt
# UI, and process argv. The user's rule: this must never happen again.
#
# How it works: Claude Code feeds hook stdin as JSON with shape
# { "tool_name": "Bash", "tool_input": { "command": "..." } }. This script
# extracts .tool_input.command, scans it with grep -E for known secret
# patterns, and if any match emits a JSON deny response on stdout. The hook
# always exits 0; the JSON on stdout is what controls the tool decision.
#
# No match: script emits nothing and exits 0 (tool proceeds as normal).
# Match: script emits a hookSpecificOutput with permissionDecision=deny
# and an explanatory permissionDecisionReason, then exits 0.
#
# Patterns block full-length secret strings only. Placeholders like
# `sk-ant-api03-...` (ellipsis) or `whsec_REDACTED` stay under the length
# thresholds and do not trigger a false positive.
#
# To test manually:
#   echo '{"tool_input":{"command":"echo sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}' | ~/.claude/hooks/secret-scan.sh
# Should print JSON with permissionDecision=deny.
#
#   echo '{"tool_input":{"command":"ls -la"}}' | ~/.claude/hooks/secret-scan.sh
# Should print nothing and exit 0.

set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Patterns use basic POSIX ERE (grep -E), no PCRE features.
# Each subpattern requires enough trailing characters to exclude placeholders
# and discussion references like "sk-ant-api03-..." or "whsec_REDACTED".
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

if printf '%s' "$CMD" | grep -qE "$PATTERN"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "secret-scan hook BLOCKED this command: it contains a string matching a known secret pattern (API key, webhook secret, AWS access key, SendGrid key, GitHub token, SSH private key, or similar). Never pass secrets as command-line arguments. The argv is persisted to shell history, Claude Code transcripts, the permission-prompt UI, and process argument space. Correct patterns: (1) set the value via the vendor dashboard yourself, no CLI involvement; (2) load the value from a file outside the repo via an env var that is resolved at execution time so the plaintext never appears in the command string; (3) use a stdin-fed CLI mode if the vendor supports it."
    }
  }'
fi

exit 0
