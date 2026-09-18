#!/usr/bin/env bash
# Covers: hook:mcp-action-guard
# Verifies mcp-action-guard.sh asks on mutating and transmitting MCP calls (R-105)
# and stays silent on read-only ones, on non-MCP tools, on the browser server, and on
# Linear-server writes, while still asking when a tracker call lands code,
# destroys state, or transmits outward.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/mcp-action-guard.sh"
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
# The tracker exemption now derives from the operator's config rather than a
# hardcoded server name, so these cases need one. Without a config the guard
# fails closed and asks, which is the intended posture and is asserted by the
# malformed-config cases further down.
NAMED_HOME=$(mktemp -d)
mkdir -p "$NAMED_HOME/.claude"
cat >"$NAMED_HOME/.claude/TICKET-TRACKER.json" <<'NAMED_TRACKER'
{
  "active": "linear",
  "trackers": {
    "linear": {
      "tools": {
        "create": "mcp__claude_ai_Linear__save_issue",
        "comment": "mcp__claude_ai_Linear__save_comment",
        "create_short": "mcp__Linear__save_issue"
      }
    }
  }
}
NAMED_TRACKER
passNamed() {
  [ -z "$(printf '{"tool_name":"%s","tool_input":{}}' "$1" | HOME="$NAMED_HOME" "$HOOK")" ]
}
askNamed() {
  printf '{"tool_name":"%s","tool_input":{}}' "$1" \
    | HOME="$NAMED_HOME" "$HOOK" \
    | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null
}
passNamed mcp__claude_ai_Linear__save_issue   # tracker write exempt: private bookkeeping
passNamed mcp__claude_ai_Linear__save_comment # tracker write exempt
passNamed mcp__Linear__save_issue             # the same server without the claude_ai prefix

# The bare-suffix shape is Cursor's alone. A different server carrying a tool
# whose suffix happens to match a configured one is NOT exempt, or the config
# would widen far past what the operator wrote.
askNamed mcp__github__save_issue              # same suffix, different server, still asks
rm -rf "$NAMED_HOME"
ask  mcp__github__create_pull_request             # a public repo is publishing, never exempt
ask  mcp__claude_ai_Notion__notion-create-pages   # only the tracker is exempt, not every writer
pass mcp__plugin_context7_context7__query-docs    # a docs lookup is not a database write
pass Write                                        # non-MCP tool

# PR #11 review: Cursor's adapter rewrites a bare MCP tool name to
# mcp__cursor__<tool>, so the real server is gone and the tracker narrowing
# above could never match under Cursor. The guard resolves the synthetic
# segment against the active tracker's own tools map, which is the one place
# that already names them. A sandbox HOME carries the config so the real one
# is never read, and the case runs in both directions: a listed tracker tool
# resolves and is exempt, an unlisted tool keeps the synthetic segment and
# still asks.
SANDBOX_HOME=$(mktemp -d)
mkdir -p "$SANDBOX_HOME/.claude"
cat >"$SANDBOX_HOME/.claude/TICKET-TRACKER.json" <<'TRACKER_JSON'
{
  "active": "Linear",
  "trackers": {
    "Linear": {
      "tools": {
        "create_issue": "mcp__claude_ai_Linear__save_issue",
        "comment": "mcp__claude_ai_Linear__save_comment"
      }
    }
  }
}
TRACKER_JSON

# askWithHome / passWithHome: the same two predicates as above, run against a
# sandbox HOME so the tracker config under test is the fixture's own.
askWithHome() {
  printf '{"tool_name":"%s","tool_input":{}}' "$1" \
    | HOME="$SANDBOX_HOME" "$HOOK" \
    | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null
}
passWithHome() {
  [ -z "$(printf '{"tool_name":"%s","tool_input":{}}' "$1" | HOME="$SANDBOX_HOME" "$HOOK")" ]
}

passWithHome mcp__cursor__save_issue    # a tracker tool under Cursor's synthetic server resolves and is exempt
passWithHome mcp__cursor__save_comment  # the second configured tracker tool, same path
askWithHome  mcp__cursor__create_page   # an unlisted tool keeps the synthetic server and still asks
askWithHome  mcp__cursor__delete_issue  # a destroy verb asks even when the tool name resolves to the tracker
rm -rf "$SANDBOX_HOME"

# An MCP server's identifier is not stable across installs. The same Linear
# server registers as `claude_ai_Linear` in one and as a bare UUID in another,
# and the first version of this exemption matched a hardcoded list of server
# NAMES, so on a UUID-registered install it never fired and every ticket write
# prompted (2026-09-18, reported from a real session). The exemption now asks
# the tracker config, which names the full tool strings including whatever
# server segment that install uses.
UUID_HOME=$(mktemp -d)
mkdir -p "$UUID_HOME/.claude"
cat >"$UUID_HOME/.claude/TICKET-TRACKER.json" <<'UUID_TRACKER'
{
  "active": "linear",
  "trackers": {
    "linear": {
      "tools": {
        "create": "mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__save_issue",
        "comment": "mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__save_comment",
        "read": "mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__get_issue"
      }
    }
  }
}
UUID_TRACKER

# askWithUuidHome / passWithUuidHome: the two predicates above, run against a
# sandbox HOME whose tracker config uses a UUID server segment.
askWithUuidHome() {
  printf '{"tool_name":"%s","tool_input":{}}' "$1" \
    | HOME="$UUID_HOME" "$HOOK" \
    | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null
}
passWithUuidHome() {
  [ -z "$(printf '{"tool_name":"%s","tool_input":{}}' "$1" | HOME="$UUID_HOME" "$HOOK")" ]
}

passWithUuidHome mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__save_issue    # the configured create tool is exempt
passWithUuidHome mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__save_comment  # the configured comment tool is exempt
askWithUuidHome  mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__delete_issue  # destroy still asks on the exempt server
askWithUuidHome  mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__merge_diff    # landing code still asks
askWithUuidHome  mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__save_project  # a write tool the config does not name still asks
askWithUuidHome  mcp__claude_ai_Notion__notion-create-pages              # another server is never exempt

# A config the schema rejects exempts nothing, the same fail-closed posture the
# malformed-config cases above assert for the previous matcher.
printf 'not json at all\n' >"$UUID_HOME/.claude/TICKET-TRACKER.json"
askWithUuidHome mcp__0ccea419-4dc2-4479-9c56-baefac2065ba__save_issue
rm -rf "$UUID_HOME"

echo "mcp-action-guard.test.sh PASS"
