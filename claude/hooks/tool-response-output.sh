#!/usr/bin/env bash
# tool-response-output.sh: sourced helper, not a hook. Reads a PostToolUse
# Bash payload's tool_response in either shape a hook can be handed: Claude
# Code's object ({stdout, stderr, interrupted, ...}) or the plain string the
# Cursor adapter passes (the whole shell output). Shared by
# draft-pr-on-first-push.sh and pr-monitor-reminder.sh (R-518, R-308), which
# both read failure and success text out of the response.

# read_tool_output <payload-json>: prints the response's output, stdout,
# stderr, and output fields joined, or the string itself.
read_tool_output() {
  jq -r '.tool_response
    | if type == "string" then .
      elif type == "object" then [.stdout, .stderr, .output] | map(strings) | join("\n")
      else "" end' 2>/dev/null <<< "$1" || true
}

# is_tool_interrupted <payload-json>: true when an object response says the
# call was interrupted or exited non-zero. A string response carries neither
# field, so its output text is the only evidence.
is_tool_interrupted() {
  jq -e '.tool_response | type == "object" and (.interrupted == true or ((.exit_code // .exitCode // 0) != 0))' \
    >/dev/null 2>&1 <<< "$1"
}
