#!/usr/bin/env bash
# agent-types.sh: Shared helper for long-running agent type checks.
# Sourced by agent-dispatch-guard.sh and agent-watchdog-instruction.sh.
# This file is the single source of truth for the long-running type list
# and for normalizing a raw type string before comparison.
#
# normalize_agent_type <raw>: prints the type lowercased, whitespace
#   removed, after dropping any "plugin:" style namespace prefix
#   (everything up to and including the last colon), and prints
#   general-purpose when the result is empty.
normalize_agent_type() {
  local raw="${1##*:}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [ -n "$raw" ] && printf '%s' "$raw" || printf '%s' "general-purpose"
}

# is_long_running_type <type>: returns 0 for long-running agent types
#   (test-author, implementer, pr-reviewer, security-reviewer,
#   general-purpose, and every audit-* role), 1 otherwise.
is_long_running_type() {
  case "$1" in
    test-author|implementer|pr-reviewer|security-reviewer|general-purpose|audit-*) return 0 ;;
    *) return 1 ;;
  esac
}
#!/usr/bin/env bash
# agent-types.sh: Shared helper for long-running agent type checks.
# Sourced by agent-dispatch-guard.sh and agent-watchdog-instruction.sh.
# This file is the single source of truth for the long-running type list
# and for normalizing a raw type string before comparison.
#
# normalize_agent_type <raw>: prints the type lowercased, whitespace
#   removed, after dropping any "plugin:" style namespace prefix
#   (everything up to and including the last colon), and prints
#   general-purpose when the result is empty.
normalize_agent_type() {
  local raw="${1##*:}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [ -n "$raw" ] && printf '%s' "$raw" || printf '%s' "general-purpose"
}

# is_long_running_type <type>: returns 0 for long-running agent types
#   (test-author, implementer, pr-reviewer, security-reviewer,
#   general-purpose, and every audit-* role), 1 otherwise.
is_long_running_type() {
  case "$1" in
    test-author|implementer|pr-reviewer|security-reviewer|general-purpose|audit-*) return 0 ;;
    *) return 1 ;;
  esac
}
