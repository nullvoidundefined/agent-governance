#!/usr/bin/env bash
# global-repo-push-guard.sh
#
# PreToolUse(Bash) hook. Enforces R-108 for the PUBLIC ~/.claude repo.
# When a `git push` is about to run from the ~/.claude working tree, it
# scans `git diff origin/main` and denies the push if the outgoing diff
# adds either:
#   1. a string matching a known secret pattern, or
#   2. this machine's real home path (the actual local-path leak vector).
#
# Scope notes:
#   - Only the ~/.claude repo is gated; pushes from any other repo pass
#     through untouched.
#   - The secret patterns MIRROR secret-scan.sh; keep the two in sync.
#     (tech-debt: extract to a shared pattern file once a second consumer
#     makes the duplication costly.)
#   - "no local filesystem paths" (R-108) is enforced as "no occurrence of
#     the real $HOME / real username home path." Generic example paths such
#     as /Users/someuser in docs are intentionally allowed, since flagging
#     every /Users/ string would block legitimate documentation and the
#     guard's own introduction.
#   - "no client-identifying content" (R-108) is semantic and stays a
#     context-only rule; this hook does not attempt it.
#
# Stdin JSON: { tool_name, tool_input: { command }, cwd }. Match emits a
# deny on stdout; no match emits nothing. Exit 0 either way.

set -euo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
if ! printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+push([[:space:]]|$)'; then
  exit 0
fi

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || exit 0

ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
ROOT_REAL=$(cd "$ROOT" 2>/dev/null && pwd -P) || exit 0
EXPECTED=$(cd "$HOME/.claude" 2>/dev/null && pwd -P) || exit 0
[ "$ROOT_REAL" = "$EXPECTED" ] || exit 0

ADDED=$(git -C "$ROOT" diff origin/main 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+' || true)
[ -n "$ADDED" ] || exit 0

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

# Secret patterns: mirror of secret-scan.sh. Keep in sync.
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

if printf '%s' "$ADDED" | grep -qE "$PATTERN"; then
  deny "global-repo-push-guard hook BLOCKED this git push: the outgoing diff (git diff origin/main) adds a string matching a known secret pattern. The ~/.claude remote is public (R-108); a pushed secret is published irreversibly. Remove the secret from the committed history before pushing."
  exit 0
fi

USER_NAME=$(id -un 2>/dev/null || echo "")
HOME_RE="/(Users|home)/${USER_NAME}(/|$)"
if printf '%s' "$ADDED" | grep -Fq "$HOME" \
   || { [ -n "$USER_NAME" ] && printf '%s' "$ADDED" | grep -qE "$HOME_RE"; }; then
  deny "global-repo-push-guard hook BLOCKED this git push: the outgoing diff (git diff origin/main) adds this machine's real home path. The ~/.claude remote is public (R-108); local filesystem paths must not be published. Replace the absolute path with a placeholder (\$HOME or ~) before pushing."
  exit 0
fi

exit 0
