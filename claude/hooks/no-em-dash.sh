#!/usr/bin/env bash
# no-em-dash.sh
#
# PreToolUse hook for Claude Code. Blocks any Write, Edit, or Bash tool
# call whose content contains the em dash character (U+2014). Enforces
# R-001 in ~/.claude/CLAUDE.md.
#
# Why this exists: the em dash is the single most recognizable AI writing
# tell. The user requires clean, AI-tell-free output and considers any em
# dash a violation of trust. R-001 is honor-system without a hook; this hook
# converts it into mechanical enforcement at the tool-call layer.
#
# How it works: Claude Code feeds hook stdin as JSON with shape
# { "tool_name": "Write"|"Edit"|"Bash", "tool_input": { ... } }.
# This script extracts the content that would land on disk (or in argv)
# depending on the tool, scans for U+2014, and if found emits a JSON
# deny response on stdout. Exit 0 either way; the JSON on stdout is
# what controls the tool decision.
#
# Matched content per tool:
#   Write: .tool_input.content
#   Edit:  .tool_input.new_string (the replacement going in)
#   Bash:  .tool_input.command (the argv string)
#
# No match: script emits nothing and exits 0 (tool proceeds as normal).
# Match: script emits hookSpecificOutput with permissionDecision=deny
# and a permissionDecisionReason explaining R-001, then exits 0.
#
# To test manually (printf generates the U+2014 byte sequence so this
# file stays em-dash-free and can itself be checked by the hook):
#   printf '{"tool_name":"Write","tool_input":{"content":"hello %s world"}}' "$(printf '\xe2\x80\x94')" | ~/.claude/hooks/no-em-dash.sh
# Should print JSON with permissionDecision=deny.
#
#   echo '{"tool_name":"Write","tool_input":{"content":"hello - world"}}' | ~/.claude/hooks/no-em-dash.sh
# Should print nothing and exit 0. (Hyphen, not em dash.)
#
#   printf '{"tool_name":"Edit","tool_input":{"new_string":"summary %s finding"}}' "$(printf '\xe2\x80\x94')" | ~/.claude/hooks/no-em-dash.sh
# Should print JSON with permissionDecision=deny.
#
#   printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m \\"fix %s typo\\""}}' "$(printf '\xe2\x80\x94')" | ~/.claude/hooks/no-em-dash.sh
# Should print JSON with permissionDecision=deny.

set -euo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')

case "$TOOL" in
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""')
    ;;
  Edit)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""')
    ;;
  Bash)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
    # Allow em dashes in search/replace tool patterns (grep, rg, sed, awk, etc.)
    # These commands legitimately need to match em dashes in file content.
    CMD_PREFIX=$(printf '%s' "$CONTENT" | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
    case "$CMD_PREFIX" in
      grep|rg|sed|awk|perl|find|ag|tr|wc|cat|head|tail|less|sort|uniq|diff|comm)
        exit 0
        ;;
    esac
    ;;
  *)
    # Tool not matched; exit silently.
    exit 0
    ;;
esac

# U+2014 is the em dash. The UTF-8 byte sequence is E2 80 94.
if printf '%s' "$CONTENT" | grep -q $'\xe2\x80\x94'; then
  jq -n --arg tool "$TOOL" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("no-em-dash hook BLOCKED this " + $tool + " call: the content contains the em dash character (U+2014). Rule R-001 in ~/.claude/CLAUDE.md forbids the em dash in any output: responses, code, comments, commit messages, markdown, prompts to subagents, test fixtures, audit reports. The em dash is the single most recognizable AI writing tell and the user considers any em dash a violation of trust. Substitute one of: period (new sentence), comma (joined clauses), semicolon (related independent clauses), colon (intro plus list), parentheses (asides), or line break. En dashes (U+2013) and hyphens (U+002D) are fine and welcome. Before retrying the tool call, scan your content once for U+2014 and apply the substitution.")
    }
  }'
fi

exit 0
