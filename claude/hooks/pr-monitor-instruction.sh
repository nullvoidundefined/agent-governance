#!/usr/bin/env bash
# pr-monitor-instruction.sh: sourced helper, not a hook. The R-518 sentence a
# session receives after any pull request is opened, shared by
# pr-monitor-reminder.sh (a successful `gh pr create` Bash call) and
# draft-pr-on-first-push.sh (a draft the hook opened itself), so both paths
# ask for exactly the same monitor switches. The switches live in the desktop
# app and no shell hook can set them; the instruction is the mechanism.

# print_monitor_instruction <pr-url>: prints the instruction for one PR.
print_monitor_instruction() {
  local url="$1"
  printf '%s' "R-518 (PR monitor): pull request ${url} is open. If the mcp__ccd_pr__set_monitor tool is available, call it now with url \"${url}\", auto_fix: true, address_comments: true, and auto_archive_on_close: true (bind the PR to this session with mcp__ccd_pr__bind_pr first if set_monitor reports it is not bound). Never call mcp__ccd_pr__set_auto_merge unless the user asks for auto-merge in the current turn (R-514 is unchanged). If those tools are absent (the CLI, no desktop app), skip this silently."
}
