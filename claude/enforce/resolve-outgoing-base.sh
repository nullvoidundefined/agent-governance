#!/usr/bin/env bash
# resolve-outgoing-base.sh: shared helper that resolves the git base ref for the outgoing diff
# on a push. Precedence: CLAUDE_ENFORCE_BASE env var > @{push} tracking ref > origin/<branch>
# remote ref > first existing of origin/main, main, origin/master, master (via merge-base) >
# nothing (empty string, callers must treat empty as "skip"). Source this file, then call
# resolve_outgoing_base.
#
# Every query runs through run_git_on_target rather than through plain git, so
# that a push aimed at another repository with `git -C`, `--git-dir` or
# `--work-tree` resolves its base in THAT repository. Before the 2026-09-18
# audit (defect 4) the base came from whichever repository the hook process was
# sitting in, which meant the wrong branch, the wrong tracking ref and, for the
# callers that went on to diff against it, the wrong file list entirely.

# run_git_on_target is defined by hooks/git-invocation.sh, which every
# push-boundary hook sources alongside this file. Defining a plain-git fallback
# here keeps this helper usable on its own and keeps a caller that never parsed
# a target on the ambient repository, which is the behaviour it always had. The
# guard means the definition order of the two files does not matter.
if ! declare -f run_git_on_target >/dev/null 2>&1; then
  run_git_on_target() { git "$@"; }
fi

resolve_outgoing_base() {
  # (a) explicit override
  if [ -n "${CLAUDE_ENFORCE_BASE:-}" ]; then
    echo "$CLAUDE_ENFORCE_BASE"
    return
  fi

  # (b) tracking push ref
  local push_ref
  push_ref=$(run_git_on_target rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null || true)
  if [ -n "$push_ref" ] && run_git_on_target rev-parse --verify -q "$push_ref" >/dev/null 2>&1; then
    echo "$push_ref"
    return
  fi

  # (c) origin/<current-branch>
  local branch
  branch=$(run_git_on_target branch --show-current 2>/dev/null || true)
  if [ -n "$branch" ] && run_git_on_target rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    echo "origin/$branch"
    return
  fi

  # (d) first existing fallback: origin/main, main, origin/master, master via merge-base
  local fallback
  for candidate in origin/main main origin/master master; do
    if run_git_on_target rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
      fallback=$(run_git_on_target merge-base "$candidate" HEAD 2>/dev/null || true)
      if [ -n "$fallback" ]; then
        echo "$fallback"
        return
      fi
    fi
  done

  # (e) nothing -- caller should exit 0 (fail open)
  echo ""
}
