#!/usr/bin/env bash
# global-repo-push-guard.sh
#
# PreToolUse(Bash) hook. Enforces R-106 for the PUBLIC agent-governance
# repo (the source that syncs into ~/.claude). When a `git push` is about
# to run from that repo's working tree, it scans `git diff origin/main`
# and denies the push if the outgoing diff adds either:
#   1. a string matching a known secret pattern, or
#   2. this machine's real home path (the actual local-path leak vector).
#
# Scope notes:
#   - Only the governance repo is gated (recognized per repo-identity.sh:
#     origin remote URL, or the legacy ~/.claude path); pushes from any
#     other repo pass through untouched. The whole monorepo diff is
#     scanned: claude/, codex/, and cursor/ publish to the same public
#     remote and are equally exposed.
#   - The secret patterns MIRROR secret-scan.sh; keep the two in sync.
#     (tech-debt: extract to a shared pattern file once a second consumer
#     makes the duplication costly.)
#   - "no local filesystem paths" (R-106) is enforced as "no occurrence of
#     the real $HOME / real username home path." Generic example paths such
#     as /Users/someuser in docs are intentionally allowed, since flagging
#     every /Users/ string would block legitimate documentation and the
#     guard's own introduction.
#   - "no client-identifying content" (R-106) is semantic and stays a
#     context-only rule; this hook does not attempt it.
#
# Stdin JSON: { tool_name, tool_input: { command }, cwd }. Match emits a
# deny on stdout; no match emits nothing. Exit 0 either way.

# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

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
# Identity is defined once in repo-identity.sh (2026-09-16 audit P0-1: the
# old inline path-equality test went dead when the repo left ~/.claude).
# A missing helper fails CLOSED to ask: this guard must never silently skip
# the publish review because its own install is incomplete, and a bare
# `source` of a missing file kills the shell under set -e with no output.
REPO_IDENTITY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-identity.sh"
if [ ! -f "$REPO_IDENTITY_HELPER" ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "global-repo-push-guard: repo-identity.sh is missing beside this hook, so the R-106 publish review cannot decide whether this push publishes the public agent-governance repo. Verify the outgoing content manually before approving."
    }
  }'
  exit 0
fi
# shellcheck source=repo-identity.sh
source "$REPO_IDENTITY_HELPER"
is_governance_repo "$ROOT" || exit 0

# Fail CLOSED when no base resolves: this is the publish guard for a public
# remote, and "cannot compute the outgoing diff" must not mean "publish
# unreviewed" (2026-07-31 security audit P2; siblings use the same resolver).
# Anchored to this script's real location, not $HOME: the fixture test runs
# the guard under a sandboxed HOME where no enforce/ tree exists.
# shellcheck source=../enforce/resolveOutgoingBase.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)/resolveOutgoingBase.sh"
BASE=$(cd "$ROOT" && resolve_outgoing_base)
if [ -z "$BASE" ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "global-repo-push-guard: cannot resolve an outgoing base (origin/main missing?), so the R-106 publish review cannot run. Verify the outgoing content manually before approving this push of the public agent-governance repo."
    }
  }'
  exit 0
fi
ADDED=$(git -C "$ROOT" diff "$BASE"..HEAD 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+' || true)
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
  deny "global-repo-push-guard hook BLOCKED this git push: the outgoing diff (git diff origin/main) adds a string matching a known secret pattern. The agent-governance remote is public (R-106); a pushed secret is published irreversibly. Remove the secret from the committed history before pushing."
  exit 0
fi

USER_NAME=$(id -un 2>/dev/null || echo "")
HOME_RE="/(Users|home)/${USER_NAME}(/|$)"
if printf '%s' "$ADDED" | grep -Fq "$HOME" \
   || { [ -n "$USER_NAME" ] && printf '%s' "$ADDED" | grep -qE "$HOME_RE"; }; then
  deny "global-repo-push-guard hook BLOCKED this git push: the outgoing diff (git diff origin/main) adds this machine's real home path. The agent-governance remote is public (R-106); local filesystem paths must not be published. Replace the absolute path with a placeholder (\$HOME or ~) before pushing."
  exit 0
fi

exit 0
