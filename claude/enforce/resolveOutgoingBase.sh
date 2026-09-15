#!/usr/bin/env bash
# resolveOutgoingBase.sh: shared helper that resolves the git base ref for the outgoing diff
# on a push. Precedence: CLAUDE_ENFORCE_BASE env var > @{push} tracking ref > origin/<branch>
# remote ref > first existing of origin/main, main, origin/master, master (via merge-base) >
# nothing (empty string, callers must treat empty as "skip"). Source this file, then call
# resolve_outgoing_base.

resolve_outgoing_base() {
  # (a) explicit override
  if [ -n "${CLAUDE_ENFORCE_BASE:-}" ]; then
    echo "$CLAUDE_ENFORCE_BASE"
    return
  fi

  # (b) tracking push ref
  local push_ref
  push_ref=$(git rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null || true)
  if [ -n "$push_ref" ] && git rev-parse --verify -q "$push_ref" >/dev/null 2>&1; then
    echo "$push_ref"
    return
  fi

  # (c) origin/<current-branch>
  local branch
  branch=$(git branch --show-current 2>/dev/null || true)
  if [ -n "$branch" ] && git rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    echo "origin/$branch"
    return
  fi

  # (d) first existing fallback: origin/main, main, origin/master, master via merge-base
  local fallback
  for candidate in origin/main main origin/master master; do
    if git rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
      fallback=$(git merge-base "$candidate" HEAD 2>/dev/null || true)
      if [ -n "$fallback" ]; then
        echo "$fallback"
        return
      fi
    fi
  done

  # (e) nothing -- caller should exit 0 (fail open)
  echo ""
}
