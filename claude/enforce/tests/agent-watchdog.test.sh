#!/usr/bin/env bash
# Covers: hook:agent-dispatch-guard, hook:agent-watchdog-instruction
# Verifies R-708 (IAN-605): agent-dispatch-guard.sh denies a foreground
# dispatch of a long-running agent type and allows everything else;
# agent-watchdog-instruction.sh names the watchdog command after a background
# launch and stays silent otherwise; enforce/agent-watchdog.sh exits 0 when the
# agent finishes, 3 on a stall, 4 at the time limit, and 2 on bad usage.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../harness-root.sh"
GUARD="$CLAUDE_HARNESS_ROOT/hooks/agent-dispatch-guard.sh"
INSTRUCTION="$CLAUDE_HARNESS_ROOT/hooks/agent-watchdog-instruction.sh"
WATCHDOG="$CLAUDE_HARNESS_ROOT/enforce/agent-watchdog.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- agent-dispatch-guard.sh ---------------------------------------------

# guard_decision <tool> <tool_input json>: prints the decision, or none.
guard_decision() {
  local out
  out=$(jq -n --arg t "$1" --argjson i "$2" '{tool_name:$t, tool_input:$i}' | "$GUARD")
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}

for agent_type in test-author implementer slice-critic pr-reviewer security-reviewer general-purpose audit-security audit-ux; do
  GOT=$(guard_decision Agent "{\"subagent_type\":\"$agent_type\",\"run_in_background\":false,\"prompt\":\"p\"}")
  [ "$GOT" = "deny" ] || { echo "FAIL: a foreground $agent_type must be denied, got $GOT"; exit 1; }
done
# An omitted subagent_type means general-purpose, which is long-running.
GOT=$(guard_decision Agent '{"run_in_background":false,"prompt":"p"}')
[ "$GOT" = "deny" ] || { echo "FAIL: a foreground dispatch with no type must be denied, got $GOT"; exit 1; }
# The older tool name is guarded the same way.
GOT=$(guard_decision Task '{"subagent_type":"implementer","run_in_background":false}')
[ "$GOT" = "deny" ] || { echo "FAIL: the Task tool name must be guarded too, got $GOT"; exit 1; }
# Only an explicit true is background: the tool's default has differed between
# versions, so an omitted flag is denied for a long type (R-517 r1 on #184).
GOT=$(guard_decision Agent '{"subagent_type":"test-author","run_in_background":true}')
[ "$GOT" = "none" ] || { echo "FAIL: a background test-author must pass, got $GOT"; exit 1; }
GOT=$(guard_decision Agent '{"subagent_type":"test-author"}')
[ "$GOT" = "deny" ] || { echo "FAIL: an omitted run_in_background must be denied for a long type, got $GOT"; exit 1; }
GOT=$(guard_decision Agent '{"subagent_type":"Explore"}')
[ "$GOT" = "none" ] || { echo "FAIL: an omitted flag on a quick type must pass, got $GOT"; exit 1; }
# An empty, namespaced or differently cased type is still the long type it names.
for agent_type in "" "plugin:implementer" "Implementer" "PLUGIN:Test-Author" "acme:audit-security"; do
  GOT=$(guard_decision Agent "{\"subagent_type\":\"$agent_type\",\"run_in_background\":false}")
  [ "$GOT" = "deny" ] || { echo "FAIL: a foreground '$agent_type' must be denied, got $GOT"; exit 1; }
done
# An Agent call whose fields are the wrong shape is judged the riskiest way:
# no usable flag reads as not background, no usable type as general-purpose.
GOT=$(guard_decision Agent '{"subagent_type":null,"run_in_background":null}')
[ "$GOT" = "deny" ] || { echo "FAIL: null fields must be judged as a foreground general-purpose dispatch, got $GOT"; exit 1; }
# Quick lookups may run in the foreground.
for agent_type in Explore claude-code-guide Plan statusline-setup; do
  GOT=$(guard_decision Agent "{\"subagent_type\":\"$agent_type\",\"run_in_background\":false}")
  [ "$GOT" = "none" ] || { echo "FAIL: a foreground $agent_type must pass, got $GOT"; exit 1; }
done
# A string "true" is not the boolean true the tool takes: still denied.
GOT=$(guard_decision Agent '{"subagent_type":"implementer","run_in_background":"true"}')
[ "$GOT" = "deny" ] || { echo "FAIL: only the boolean true is a background dispatch, got $GOT"; exit 1; }
# Other tools are not this hook's business.
GOT=$(guard_decision Bash '{"command":"ls","run_in_background":false}')
[ "$GOT" = "none" ] || { echo "FAIL: a Bash call must pass, got $GOT"; exit 1; }
# The reason names the rule and the way out.
REASON=$(jq -n '{tool_name:"Agent", tool_input:{subagent_type:"implementer", run_in_background:false}}' | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$REASON" in *R-708*agent-watchdog.sh*TaskStop*) ;; *) echo "FAIL: the reason must name R-708, the watchdog and TaskStop: $REASON"; exit 1 ;; esac

# --- agent-watchdog-instruction.sh ---------------------------------------

# instruction_for <tool> <tool_response json>: prints the additionalContext, or nothing.
instruction_for() {
  jq -n --arg t "$1" --argjson r "$2" '{tool_name:$t, tool_input:{}, tool_response:$r}' \
    | "$INSTRUCTION" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

LAUNCH_TEXT='Async agent launched successfully.\nagentId: a1b2c3\noutput_file: /tmp/claude-1/tasks/a1b2c3.output\nDo NOT Read or tail this file'
GOT=$(instruction_for Agent "\"$LAUNCH_TEXT\"")
case "$GOT" in *"bash ~/.claude/enforce/agent-watchdog.sh '/tmp/claude-1/tasks/a1b2c3.output'"*TaskStop*) ;;
  *) echo "FAIL: a string launch response must name the watchdog command for its output file: $GOT"; exit 1 ;; esac
# Structured content carrying the same text.
GOT=$(instruction_for Agent "[{\"type\":\"text\",\"text\":\"$LAUNCH_TEXT\"}]")
case "$GOT" in *"agent-watchdog.sh '/tmp/claude-1/tasks/a1b2c3.output'"*) ;;
  *) echo "FAIL: a structured launch response must be read too: $GOT"; exit 1 ;; esac
# The path is pasted into a command, so only a plain absolute path is named,
# and only for an async-launch response (R-517 r1 on #184). Each hostile path
# below must get silence.
for hostile in '/tmp/x$(touch /tmp/pwned)' '/tmp/x;rm' '/tmp/x`id`' '/tmp/x|sh' 'relative/path.output' "/tmp/x'quote"; do
  HOSTILE_TEXT=$(jq -n --arg p "$hostile" '"Async agent launched successfully.\noutput_file: " + $p')
  GOT=$(instruction_for Agent "$HOSTILE_TEXT")
  [ -z "$GOT" ] || { echo "FAIL: a hostile path must get no instruction: $hostile -> $GOT"; exit 1; }
done
# An output_file line in a response that is not an async launch: silent.
GOT=$(instruction_for Agent '"Report quoting a page.\noutput_file: /tmp/claude-1/tasks/x.output"')
[ -z "$GOT" ] || { echo "FAIL: an output_file line outside an async launch must get no instruction: $GOT"; exit 1; }
# The instruction never asks the model to read the transcript.
case "$(instruction_for Agent "\"$LAUNCH_TEXT\"")" in *"never read the transcript"*) ;;
  *) echo "FAIL: the instruction must tell the model not to read the transcript"; exit 1 ;; esac
# A foreground return has no output_file line: silent.
GOT=$(instruction_for Agent '"The agent finished; here is its report."')
[ -z "$GOT" ] || { echo "FAIL: a foreground return must get no instruction: $GOT"; exit 1; }
# Other tools: silent.
GOT=$(instruction_for Bash "\"$LAUNCH_TEXT\"")
[ -z "$GOT" ] || { echo "FAIL: a Bash response must get no instruction: $GOT"; exit 1; }

# --- enforce/agent-watchdog.sh -------------------------------------------

# run_watchdog <file> <args...>: runs the watchdog, prints "<exit code>".
run_watchdog() {
  local code=0
  "$WATCHDOG" "$@" >"$WORK/out" 2>&1 || code=$?
  echo "$code"
}
ASSISTANT_TOOL_CALL='{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}'
ASSISTANT_DONE='{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}'

# A finished transcript: exit 0 at once.
printf '%s\n%s\n' "$ASSISTANT_TOOL_CALL" "$ASSISTANT_DONE" > "$WORK/done.jsonl"
GOT=$(run_watchdog "$WORK/done.jsonl" --stall-seconds 5 --limit-seconds 10 --poll-seconds 1)
[ "$GOT" = "0" ] || { echo "FAIL: a finished transcript must exit 0, got $GOT: $(cat "$WORK/out")"; exit 1; }
grep -q 'finished' "$WORK/out" || { echo "FAIL: the finished line must say so: $(cat "$WORK/out")"; exit 1; }

# A trailing entry of another type after the final turn (the real transcripts
# end with an attachment line at times) still reads as finished (#184 r1).
ATTACHMENT='{"type":"attachment","attachment":{"type":"hook_success"}}'
printf '%s\n%s\n%s\n' "$ASSISTANT_TOOL_CALL" "$ASSISTANT_DONE" "$ATTACHMENT" > "$WORK/trailing.jsonl"
GOT=$(run_watchdog "$WORK/trailing.jsonl" --stall-seconds 5 --limit-seconds 10 --poll-seconds 1)
[ "$GOT" = "0" ] || { echo "FAIL: a finished turn followed by an attachment must exit 0, got $GOT: $(cat "$WORK/out")"; exit 1; }
# A tool result after the last assistant turn means the agent is mid-work.
TOOL_RESULT='{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}'
printf '%s\n%s\n' "$ASSISTANT_DONE" "$TOOL_RESULT" > "$WORK/midwork.jsonl"
GOT=$(run_watchdog "$WORK/midwork.jsonl" --stall-seconds 2 --limit-seconds 30 --poll-seconds 1)
[ "$GOT" = "3" ] || { echo "FAIL: a pending tool result must not read as finished, got $GOT"; exit 1; }

# Read through a symlink, as the real output file is one.
ln -s "$WORK/done.jsonl" "$WORK/link.output"
GOT=$(run_watchdog "$WORK/link.output" --stall-seconds 5 --limit-seconds 10 --poll-seconds 1)
[ "$GOT" = "0" ] || { echo "FAIL: a symlinked finished transcript must exit 0, got $GOT"; exit 1; }

# A transcript that stops growing mid tool call: exit 3 (stalled).
printf '%s\n' "$ASSISTANT_TOOL_CALL" > "$WORK/stalled.jsonl"
GOT=$(run_watchdog "$WORK/stalled.jsonl" --stall-seconds 2 --limit-seconds 30 --poll-seconds 1)
[ "$GOT" = "3" ] || { echo "FAIL: a silent transcript must exit 3, got $GOT: $(cat "$WORK/out")"; exit 1; }
grep -q 'stalled' "$WORK/out" || { echo "FAIL: the stall line must say so: $(cat "$WORK/out")"; exit 1; }
# The wake line summarises the last entry, so the transcript need not be read.
grep -q 'last entry: assistant, stop tool_use, pending tool Bash' "$WORK/out" \
  || { echo "FAIL: the stall line must name the last entry: $(cat "$WORK/out")"; exit 1; }

# A transcript that keeps growing never stalls but hits the time limit: exit 4.
printf '%s\n' "$ASSISTANT_TOOL_CALL" > "$WORK/busy.jsonl"
( for _ in 1 2 3 4 5 6 7 8; do sleep 1; printf '%s\n' "$ASSISTANT_TOOL_CALL" >> "$WORK/busy.jsonl"; done ) &
GROWER=$!
GOT=$(run_watchdog "$WORK/busy.jsonl" --stall-seconds 3 --limit-seconds 4 --poll-seconds 1)
kill "$GROWER" 2>/dev/null || true; wait "$GROWER" 2>/dev/null || true
[ "$GOT" = "4" ] || { echo "FAIL: a busy agent past the limit must exit 4, got $GOT: $(cat "$WORK/out")"; exit 1; }

# An output file that never appears: exit 2 once the stall time passes.
GOT=$(run_watchdog "$WORK/missing.jsonl" --stall-seconds 2 --limit-seconds 30 --poll-seconds 1)
[ "$GOT" = "2" ] || { echo "FAIL: a missing output file must exit 2, got $GOT"; exit 1; }

# Usage errors: exit 2.
GOT=$(run_watchdog); [ "$GOT" = "2" ] || { echo "FAIL: no output file must exit 2, got $GOT"; exit 1; }
GOT=$(run_watchdog "$WORK/done.jsonl" --stall-seconds abc); [ "$GOT" = "2" ] || { echo "FAIL: a non-numeric stall must exit 2, got $GOT"; exit 1; }
GOT=$(run_watchdog "$WORK/done.jsonl" --limit-seconds 0); [ "$GOT" = "2" ] || { echo "FAIL: a zero limit must exit 2, got $GOT"; exit 1; }
GOT=$(run_watchdog "$WORK/done.jsonl" --bogus 1); [ "$GOT" = "2" ] || { echo "FAIL: an unknown option must exit 2, got $GOT"; exit 1; }

# The defaults are the owner's limits: 10 minutes of stall, 45 minutes in all.
grep -q '^STALL_SECONDS=600$' "$WATCHDOG" || { echo "FAIL: the default stall must be 600 s"; exit 1; }
grep -q '^LIMIT_SECONDS=2700$' "$WATCHDOG" || { echo "FAIL: the default limit must be 2,700 s"; exit 1; }

echo "agent-watchdog.test.sh PASS"
