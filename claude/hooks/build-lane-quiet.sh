#!/usr/bin/env bash
# build-lane-quiet.sh: a sourced helper, not a hook (IAN-401, spec
# 2026-09-27-build-fast-design.md B-6). The six reminder-only hooks call
# is_reminder_quiet and stay silent in the build-fast fast lane, where the
# owner chose speed over advisory nudges. No blocking hook sources this file.
# Sourced, never executed: it sets no shell options and defines one function.
# Bash 3.2 compatible.

# is_reminder_quiet <path>: returns 0 only when the repository holding <path>
# (a file, a directory, or a path not yet written) has an untracked, regular
# .claude/task-tier.json that parses as one JSON object, names the checked-out
# branch, and records lane "fast"; returns 1 otherwise, so any doubt keeps the
# reminder. A committed ledger, a symlinked ledger, or a ledger reached through
# a symlinked .claude directory is not the owner's opt-in for this checkout, so
# it never silences anything.
is_reminder_quiet() {
  local probe="$1" top branch
  [ -n "$probe" ] || return 1
  # A path not yet on disk (a Write payload's target) resolves through its
  # nearest existing parent directory.
  while [ ! -d "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do
    probe=$(dirname -- "$probe")
  done
  top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null) || return 1
  branch=$(git -C "$top" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -s "$top/.claude/task-tier.json" ] || return 1
  [ -L "$top/.claude" ] && return 1
  [ -L "$top/.claude/task-tier.json" ] && return 1
  # :(icase) because a case-insensitive filesystem opens .Claude/task-tier.json
  # through this path while a case-sensitive pathspec would miss it in the index.
  git -C "$top" ls-files --error-unmatch -- ':(icase).claude/task-tier.json' >/dev/null 2>&1 && return 1
  jq -es --arg b "$branch" 'length == 1 and (.[0] | type) == "object" and .[0].branch == $b and .[0].lane == "fast"' \
    "$top/.claude/task-tier.json" >/dev/null 2>&1
}
