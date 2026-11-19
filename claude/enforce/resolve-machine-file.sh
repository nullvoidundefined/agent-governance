#!/usr/bin/env bash
# resolve-machine-file.sh: resolves the machine file path safely.
#
# With AGENT_TIER_ASSIGNMENTS_FILE set, yields that path.
# With it unset and HOME set, yields $HOME/.claude/agent-tier-assignments.json.
# With both unset, yields empty (the caller must not use a /.claude/ path).
#
# Usage: source this file, then call resolve_machine_file.
# Sets the variable MACHINE_FILE_PATH.
resolve_machine_file() {
  if [ -n "${AGENT_TIER_ASSIGNMENTS_FILE:-}" ]; then
    MACHINE_FILE_PATH="$AGENT_TIER_ASSIGNMENTS_FILE"
  elif [ -n "${HOME:-}" ]; then
    MACHINE_FILE_PATH="$HOME/.claude/agent-tier-assignments.json"
  else
    MACHINE_FILE_PATH=""
  fi
}
