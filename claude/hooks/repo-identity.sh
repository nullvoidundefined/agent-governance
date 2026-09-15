#!/usr/bin/env bash
# repo-identity.sh: the one definition of "this is the public agent-governance
# repo" (R-106). Source this from any hook that must recognize the governance
# repo; never re-derive the identity inline. The 2026-09-16 audit found the
# identity re-derived independently in 8+ places, and every path-based copy
# went silently dead when the repo moved out of ~/.claude (P0-1).
# Recognition is dual, either check suffices:
#   - durable: the toplevel's `origin` remote URL contains
#     GOVERNANCE_REMOTE_ID; holds for any local clone or CI checkout.
#   - legacy: the toplevel is realpath $HOME/.claude (pre-migration layout,
#     kept so an old-style install stays guarded).

GOVERNANCE_REMOTE_ID='nullvoidundefined/agent-governance'

is_governance_repo() { # usage: is_governance_repo <dir-inside-repo>
  local top top_real legacy origin_url
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  origin_url=$(git -C "$top" remote get-url origin 2>/dev/null || true)
  case "$origin_url" in *"$GOVERNANCE_REMOTE_ID"*) return 0 ;; esac
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  legacy=$(cd "$HOME/.claude" 2>/dev/null && pwd -P) || return 1
  [ "$top_real" = "$legacy" ]
}
