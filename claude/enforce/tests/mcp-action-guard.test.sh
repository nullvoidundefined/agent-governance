#!/usr/bin/env bash
# Verifies mcp-action-guard.sh asks on mutating and transmitting MCP calls (R-105)
# and stays silent on read-only ones, on non-MCP tools, and on the browser server.
set -euo pipefail
HOOK="$HOME/.claude/hooks/mcp-action-guard.sh"
ask() { printf '{"tool_name":"%s","tool_input":{}}' "$1" | "$HOOK" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null; }
pass() { [ -z "$(printf '{"tool_name":"%s","tool_input":{}}' "$1" | "$HOOK")" ]; }

ask  mcp__claude_ai_Gmail__send_message           # transmits
ask  mcp__claude_ai_Gmail__forward                # transmits
ask  mcp__claude_ai_Gmail__trash_thread           # destroys
ask  mcp__claude_ai_Linear__save_issue            # writes
ask  mcp__claude_ai_Linear__merge_diff            # writes
ask  mcp__claude_ai_Notion__notion-create-pages   # verb behind a server prefix
ask  mcp__claude_ai_Notion__notion-update-page    # verb behind a server prefix
ask  mcp__claude_ai_Google_Calendar__delete_event # destroys
ask  mcp__claude_ai_Figma__create_new_file        # writes

pass mcp__claude_ai_Gmail__search_threads         # read-only
pass mcp__claude_ai_Gmail__list_labels            # read-only
pass mcp__claude_ai_Linear__get_issue             # read-only
pass mcp__claude_ai_Notion__notion-fetch          # read-only
pass mcp__claude_ai_Google_Drive__download_file_content   # read-only
pass mcp__claude_ai_Linear__list_issue_labels     # 'labels' is not the verb 'label'
pass mcp__claude_ai_Gmail__untrash_message        # restorative, not destructive
pass mcp__claude-in-chrome__tabs_create_mcp       # browser server exempt
pass Write                                        # non-MCP tool

echo "mcp-action-guard.test.sh PASS"
