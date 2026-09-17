#!/usr/bin/env bash
# Verifies mcp-action-guard.sh asks on mutating and transmitting MCP calls (R-105)
# and stays silent on read-only ones, on non-MCP tools, and on the browser server.
set -euo pipefail
HOOK="$HOME/.claude/hooks/mcp-action-guard.sh"
TRACKER_CONFIG=$(mktemp)
trap 'rm -f "$TRACKER_CONFIG"' EXIT
export TICKET_TRACKER_CONFIG="$TRACKER_CONFIG/nonexistent"

# Checks that the hook asks for permission for the tool name in argument 1.
# Prints nothing on success and returns 0; returns nonzero on failure.
ask() { printf '{"tool_name":"%s","tool_input":{}}' "$1" | "$HOOK" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null; }
# Checks that the hook silently allows the tool name in argument 1.
# Prints nothing and returns 0 for empty output; returns nonzero otherwise.
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
ask  mcp__github__createIssue                     # camelCase name
ask  mcp__github__createPullRequest               # camelCase, multi-word
ask  mcp__slack__chat_postMessage                 # camelCase behind a prefix
ask  mcp__neon__run_sql                           # statements against a database
ask  mcp__supabase__execute_sql                   # statements against a database
ask  mcp__supabase__apply_migration               # schema change
ask  mcp__claude_ai_Figma__use_figma              # the Figma server's own write path

pass mcp__claude_ai_Gmail__search_threads         # read-only
pass mcp__claude_ai_Gmail__list_labels            # read-only
pass mcp__claude_ai_Linear__get_issue             # read-only
pass mcp__claude_ai_Notion__notion-fetch          # read-only
pass mcp__claude_ai_Google_Drive__download_file_content   # read-only
pass mcp__claude_ai_Linear__list_issue_labels     # 'labels' is not the verb 'label'
pass mcp__claude_ai_Gmail__untrash_message        # restorative, not destructive
pass mcp__claude-in-chrome__tabs_create_mcp       # browser server exempt
pass mcp__plugin_context7_context7__query-docs    # a docs lookup is not a database write
pass Write                                        # non-MCP tool

# Only tools listed under the active tracker are pre-authorized.
printf '%s\n' '{"active":"linear","trackers":{"linear":{"tools":{"create":"mcp__claude_ai_Linear__save_issue","comment":"mcp__claude_ai_Linear__save_comment"}}}}' >"$TRACKER_CONFIG"
export TICKET_TRACKER_CONFIG="$TRACKER_CONFIG"
pass mcp__claude_ai_Linear__save_issue
pass mcp__claude_ai_Linear__save_comment
ask  mcp__claude_ai_Linear__delete_issue_label
ask  mcp__claude_ai_Gmail__send_message

# Missing and malformed configs do not pre-authorize tracker writes.
export TICKET_TRACKER_CONFIG="$TRACKER_CONFIG/nonexistent"
ask mcp__claude_ai_Linear__save_issue
printf '%s\n' '{not json' >"$TRACKER_CONFIG"
export TICKET_TRACKER_CONFIG="$TRACKER_CONFIG"
ask mcp__claude_ai_Linear__save_issue

# An array of tool names cannot pre-authorize tracker writes.
printf '%s\n' '{"active":"linear","trackers":{"linear":{"tools":["mcp__claude_ai_Linear__save_issue"]}}}' >"$TRACKER_CONFIG"
ask mcp__claude_ai_Linear__save_issue

# A string tool name cannot pre-authorize tracker writes.
printf '%s\n' '{"active":"linear","trackers":{"linear":{"tools":"mcp__claude_ai_Linear__save_issue"}}}' >"$TRACKER_CONFIG"
ask mcp__claude_ai_Linear__save_issue

# A matching object followed by another JSON value is not a valid config.
printf '%s\n' '{"active":"linear","trackers":{"linear":{"tools":{"create":"mcp__claude_ai_Linear__save_issue"}}}}' '"second"' >"$TRACKER_CONFIG"
ask mcp__claude_ai_Linear__save_issue

# An array wrapping a matching object cannot pre-authorize tracker writes.
printf '%s\n' '[{"active":"linear","trackers":{"linear":{"tools":{"create":"mcp__claude_ai_Linear__save_issue"}}}}]' >"$TRACKER_CONFIG"
ask mcp__claude_ai_Linear__save_issue

# An absent active tracker cannot use tools listed under another tracker.
printf '%s\n' '{"active":"missing","trackers":{"linear":{"tools":{"create":"mcp__claude_ai_Linear__save_issue"}}}}' >"$TRACKER_CONFIG"
ask mcp__claude_ai_Linear__save_issue

echo "mcp-action-guard.test.sh PASS"
