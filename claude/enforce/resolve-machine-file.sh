#!/usr/bin/env bash
# resolve-machine-file.sh: prints the machine file path on stdout.
#
# Precedence: $AGENT_TIER_ASSIGNMENTS_FILE; else $CLAUDE_HOME/agent-tier-
#   assignments.json when CLAUDE_HOME is set; else
#   $HOME/.claude/agent-tier-assignments.json when HOME is set; else empty
#   (the caller must not use a /.claude/ path).
#
# Usage: source this file, then capture the output:
#   machine=$(resolve_machine_file)
resolve_machine_file() {
  if [ -n "${AGENT_TIER_ASSIGNMENTS_FILE:-}" ]; then
    printf '%s\n' "$AGENT_TIER_ASSIGNMENTS_FILE"
  elif [ -n "${CLAUDE_HOME:-}" ]; then
    printf '%s\n' "$CLAUDE_HOME/agent-tier-assignments.json"
  elif [ -n "${HOME:-}" ]; then
    printf '%s\n' "$HOME/.claude/agent-tier-assignments.json"
  else
    printf '\n'
  fi
}
