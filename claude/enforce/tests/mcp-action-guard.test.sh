#!/usr/bin/env bash
# Verifies mcp-action-guard.sh asks on mutating and transmitting MCP calls (R-105)
# and stays silent on read-only ones, on non-MCP tools, on the browser server, and on
# Linear-server writes, while still asking when a tracker call lands code,
# destroys state, or transmits outward.
set -euo pipefail
HOOK="$HOME/.claude/hooks/mcp-action-guard.sh"
ask() { printf '{"tool_name":"%s","tool_input":{}}' "$1" | "$HOOK" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null; }
pass() { [ -z "$(printf '{"tool_name":"%s","tool_input":{}}' "$1" | "$HOOK")" ]; }

ask  mcp__claude_ai_Gmail__send_message           # transmits
ask  mcp__claude_ai_Gmail__forward                # transmits
ask  mcp__claude_ai_Gmail__trash_thread           # destroys
ask  mcp__claude_ai_Linear__merge_diff            # lands code, so it asks despite the tracker exemption
ask  mcp__claude_ai_Linear__delete_comment        # destroys, so it asks despite the tracker exemption
ask  mcp__claude_ai_Linear__share_issue           # transmits outward, so it asks despite the tracker exemption
ask  mcp__claude_ai_Linear__submit_diff_review    # submits for review, so it asks despite the tracker exemption
ask  mcp__claude_ai_Linear__create_attachment_from_upload  # carries a file out, so it asks
ask  mcp__claude_ai_Linear__retire_issue_label    # retiring a label destroys state, so it asks
ask  mcp__claude_ai_Linear__save_share_issue      # a write token first does not let a transmit token through
ask  mcp__claude_ai_Linear__save_delete_comment   # a write token first does not let a destroy token through
ask  mcp__claude_ai_Linear__create_and_share      # the strongest class an action names decides, not the first
ask  mcp__claude_ai_Linear__apply_template        # apply is held back on the exempt server too
ask  mcp__github__retire_thing                    # the destroy class covers retire on every server
ask  mcp__claude_ai_Linear__retract_invite        # retract is a destroy verb too, on the exempt server
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
pass mcp__claude_ai_Linear__save_issue            # tracker write exempt: private bookkeeping
pass mcp__claude_ai_Linear__save_comment          # tracker write exempt
pass mcp__Linear__save_issue                      # the same server without the claude_ai prefix
ask  mcp__github__create_pull_request             # a public repo is publishing, never exempt
ask  mcp__claude_ai_Notion__notion-create-pages   # only the tracker is exempt, not every writer
pass mcp__plugin_context7_context7__query-docs    # a docs lookup is not a database write
pass Write                                        # non-MCP tool

echo "mcp-action-guard.test.sh PASS"
