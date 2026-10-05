#!/usr/bin/env bash
# audit-log.sh: PostToolUse hook, matcher ".*" (spec
# docs/specs/2026-10-05-audit-log.md, A-1 to A-8). Appends one `tool` line per
# completed tool call to ${AGENT_AUDIT_DIR:-$HOME/.local/state/agent-audit}/
# <UTC date>.jsonl, so after an incident the owner can check what the agent
# actually ran against what it reported. The line format, redaction, cap,
# rotation and single-write rule live in audit-log-append.sh, which the guards
# source for their `decision` lines.
#
# Never blocks and never prints: every outcome, a missing jq, an unwritable
# directory, a malformed or empty payload included, is exit 0 with no output.
# Ceiling: the log is written as the session's own OS user, so a program the
# agent writes and runs can still change it; protected-path-guard.sh stops the
# agent's own tools from doing so.
exec 2>/dev/null
INPUT=$(cat)
AUDIT_LOG_HELPER="${BASH_SOURCE[0]%/*}/audit-log-append.sh"
[ "$AUDIT_LOG_HELPER" != "${BASH_SOURCE[0]}/audit-log-append.sh" ] || AUDIT_LOG_HELPER="./audit-log-append.sh"
if [ -f "$AUDIT_LOG_HELPER" ] && . "$AUDIT_LOG_HELPER" >/dev/null; then
  audit_log_append "$INPUT" tool
fi
exit 0
