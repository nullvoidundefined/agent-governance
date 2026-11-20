#!/usr/bin/env bash
# Covers: enforce/route.sh
# route.test.sh: verifies the tier resolver (slice 05 PR 1,
# docs/slices/slice-05-tiered-agents-and-local-qwen-implementer.md).
# route.sh <step> --risk <high|standard> [--author X] [--security] prints the
# agent on line 1 (claude, qwen or owner) and a one-line reason on line 2, and
# appends one JSON line (ts, step, risk, tier, provider, reason) to
# $ROUTING_LOG. The step and risk give a tier (route-steps.json); the machine
# file ($AGENT_TIER_ASSIGNMENTS_FILE, default ~/.claude/agent-tier-assignments.json)
# gives the agent for that tier. Known agents: claude, qwen. An unset or
# unknown tier resolves to primary; primary defaults to claude.
#
# Every case writes its own machine file in a temp directory and points
# AGENT_TIER_ASSIGNMENTS_FILE at it, so no case reads the live machine file.
# CLAUDE_QUOTA_FILE points at a path that never exists: routing must not
# depend on quota.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/route.sh"
STEPS="$CLAUDE_HARNESS_ROOT/enforce/route-steps.json"
TEMPLATE="$CLAUDE_HARNESS_ROOT/agent-tier-assignments.template.json"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_QUOTA_FILE="$WORK/no-such-quota.json"
export ROUTING_LOG="$WORK/routing-log.jsonl"
unset AGENT_TIER_ASSIGNMENTS_FILE
# CLAUDE_HOME names the Claude config directory and outranks $HOME/.claude;
# unset so the HOME-default cases below test HOME, not the caller's setting.
unset CLAUDE_HOME

# Every step the new table names, in the order the grids walk them.
STEPS_ROUTED="spec test-author review implement security-review"

failCase() {
  echo "FAIL: $1"
  exit 1
}

# useMachineFile <path>: points the router at that machine file.
useMachineFile() {
  export AGENT_TIER_ASSIGNMENTS_FILE="$1"
}

# writeMachineFile <json>: writes a machine file in the temp dir, points the
# router at it, and checks the JSON is what the case meant to write.
writeMachineFile() {
  printf '%s\n' "$1" >"$WORK/machine.json"
  jq -e . "$WORK/machine.json" >/dev/null || failCase "setup: machine file JSON is malformed: $1"
  useMachineFile "$WORK/machine.json"
}

# route <args...>: runs the router; sets RC, OUT (stdout), ERR (stderr), P
# (line 1) and REASON (line 2).
route() {
  RC=0
  OUT=$(bash "$SCRIPT" "$@" 2>"$WORK/err") || RC=$?
  ERR=$(cat "$WORK/err")
  P=$(printf '%s\n' "$OUT" | sed -n 1p)
  REASON=$(printf '%s\n' "$OUT" | sed -n 2p)
}

# routeOk <args...>: runs the router and fails unless it exited 0 with an
# agent on line 1 and a reason on line 2, and nothing after.
routeOk() {
  route "$@"
  [ "$RC" -eq 0 ] || failCase "route $* exited $RC (stdout: '$OUT', stderr: $ERR)"
  case "$P" in claude | qwen | owner) ;; *) failCase "route $*: line 1 must be claude, qwen or owner (got '$P')" ;; esac
  [ -n "$REASON" ] || failCase "route $*: line 2 must carry a reason"
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "2" ] || failCase "route $*: stdout must be exactly two lines (got '$OUT')"
}

# expectRoute <want> <args...>: routeOk, then line 1 must equal want.
expectRoute() {
  local want="$1"
  shift
  routeOk "$@"
  [ "$P" = "$want" ] || failCase "route $*: want $want, got $P ($REASON)"
}

# expectStep <want> <step> <risk>: expectRoute, adding --author claude for review.
expectStep() {
  if [ "$2" = review ]; then
    expectRoute "$1" "$2" --risk "$3" --author claude
  else
    expectRoute "$1" "$2" --risk "$3"
  fi
}

# reasonHas <text> <what>: line 2 of the last call must contain text, any case.
reasonHas() {
  printf '%s\n' "$REASON" | grep -qi -- "$1" || failCase "$2: reason must mention '$1' (got: $REASON)"
}

logCount() {
  if [ -f "$ROUTING_LOG" ]; then wc -l <"$ROUTING_LOG" | tr -d ' '; else echo 0; fi
}

# allPrimary <want> <what>: every step but merge, at both risks, prints want;
# merge prints owner.
allPrimary() {
  local step risk
  for step in $STEPS_ROUTED; do
    for risk in standard high; do
      expectStep "$1" "$step" "$risk"
    done
  done
  expectRoute owner merge --risk standard
  expectRoute owner merge --risk high
}

# --- 0. The checked-in template exists and has the documented shape. ---
[ -f "$TEMPLATE" ] || failCase "the template machine file must exist at $TEMPLATE"
jq -e '.primary.agent == "claude" and .secondary.agent == "qwen"
  and .secondary.model == "qwen-coder-local" and .secondary.endpoint == "http://127.0.0.1:11434"' \
  "$TEMPLATE" >/dev/null || failCase "the template must assign primary claude and secondary qwen (qwen-coder-local at http://127.0.0.1:11434)"

# --- 1-4. The template as machine file. ---
useMachineFile "$TEMPLATE"
# 1. Standard-risk implement goes to the secondary agent.
expectRoute qwen implement --risk standard
# 2. High-risk implement overrides to primary.
expectRoute claude implement --risk high
# 3. spec, test-author, review are primary at either risk.
for risk in standard high; do
  expectRoute claude spec --risk "$risk"
  expectRoute claude test-author --risk "$risk"
  expectRoute claude review --risk "$risk" --author claude
  expectRoute claude security-review --risk "$risk"
  reasonHas fable "security-review --risk $risk"
done
# 4. merge is owner.
expectRoute owner merge --risk standard
expectRoute owner merge --risk high
# The agent alone is on line 1: no extra words.
routeOk implement --risk standard
[ "$P" = "qwen" ] || failCase "line 1 must be only the agent name (got '$P')"

# --- 5. No machine file: every step is claude, merge is owner, the reason says so. ---
useMachineFile "$WORK/no-such-machine-file.json"
allPrimary claude "no machine file"
for step in $STEPS_ROUTED; do
  expectStep claude "$step" standard
  reasonHas "no machine file" "$step with no machine file"
done
# The default path is ~/.claude/agent-tier-assignments.json.
mkdir -p "$WORK/home/.claude"
printf '%s\n' '{"primary": {"agent": "qwen"}}' >"$WORK/home/.claude/agent-tier-assignments.json"
DEFAULT_OUT=$(
  unset AGENT_TIER_ASSIGNMENTS_FILE
  HOME="$WORK/home" bash "$SCRIPT" spec --risk standard 2>/dev/null
) || failCase "route with AGENT_TIER_ASSIGNMENTS_FILE unset must succeed"
[ "$(printf '%s\n' "$DEFAULT_OUT" | sed -n 1p)" = "qwen" ] ||
  failCase "with AGENT_TIER_ASSIGNMENTS_FILE unset, the machine file is \$HOME/.claude/agent-tier-assignments.json (got '$DEFAULT_OUT')"

# --- 6. A machine file that is not JSON: claude, one stderr warning, exit 0. ---
printf 'not json {\n' >"$WORK/bad.json"
useMachineFile "$WORK/bad.json"
for step in $STEPS_ROUTED; do
  for risk in standard high; do
    expectStep claude "$step" "$risk"
    [ "$(printf '%s\n' "$ERR" | grep -c .)" = "1" ] ||
      failCase "$step --risk $risk with an invalid machine file: want exactly one warning line on stderr (got: '$ERR')"
  done
done
expectRoute owner merge --risk standard
expectRoute owner merge --risk high

# --- 4. merge is owner whatever the machine file says. ---
writeMachineFile '{"primary": {"agent": "qwen"}, "secondary": {"agent": "qwen"}, "owner": {"agent": "claude"}}'
expectRoute owner merge --risk standard
expectRoute owner merge --risk high

# --- 7. secondary unset: implement standard goes to the primary agent. ---
writeMachineFile '{"primary": {"agent": "claude"}}'
expectRoute claude implement --risk standard
writeMachineFile '{"primary": {"agent": "qwen"}}'
expectRoute qwen implement --risk standard

# --- 8. secondary is an unknown agent: primary agent, reason names it. ---
writeMachineFile '{"primary": {"agent": "claude"}, "secondary": {"agent": "gemini"}}'
expectRoute claude implement --risk standard
reasonHas gemini "implement with secondary gemini"
writeMachineFile '{"primary": {"agent": "qwen"}, "secondary": {"agent": "gemini"}}'
expectRoute qwen implement --risk standard
reasonHas gemini "implement with secondary gemini and primary qwen"

# --- 9. primary unset or unknown: the primary agent is claude. ---
writeMachineFile '{"secondary": {"agent": "qwen"}}'
for risk in standard high; do
  expectRoute claude spec --risk "$risk"
  expectRoute claude test-author --risk "$risk"
  expectRoute claude review --risk "$risk" --author claude
  expectRoute claude security-review --risk "$risk"
done
expectRoute claude implement --risk high
expectRoute qwen implement --risk standard
writeMachineFile '{"primary": {"agent": "gemini"}, "secondary": {"agent": "qwen"}}'
for risk in standard high; do
  expectRoute claude spec --risk "$risk"
  expectRoute claude test-author --risk "$risk"
  expectRoute claude review --risk "$risk" --author claude
  expectRoute claude security-review --risk "$risk"
done
expectRoute claude implement --risk high
expectRoute qwen implement --risk standard
# Neither tier usable: implement standard falls all the way back to claude.
writeMachineFile '{"primary": {"agent": "gemini"}, "secondary": {"agent": "gemini"}}'
expectRoute claude implement --risk standard

# --- 10. Each routed call appends exactly one JSON line with the documented keys. ---
useMachineFile "$TEMPLATE"
rm -f "$ROUTING_LOG"
routeOk implement --risk standard
[ "$(logCount)" = "1" ] || failCase "one routed call must append exactly one log line (got $(logCount))"
routeOk implement --risk high
[ "$(logCount)" = "2" ] || failCase "a second routed call must append exactly one more line (got $(logCount))"
routeOk merge --risk standard
[ "$(logCount)" = "3" ] || failCase "a third routed call must append exactly one more line (got $(logCount))"
L1=$(sed -n 1p "$ROUTING_LOG")
jq -e . >/dev/null 2>&1 <<<"$L1" || failCase "log line must be JSON: $L1"
for key in ts step risk tier provider reason; do
  jq -e --arg k "$key" 'has($k)' >/dev/null <<<"$L1" || failCase "log line must carry key $key: $L1"
done
[ -n "$(jq -r .ts <<<"$L1")" ] || failCase "log ts must not be empty"
[ "$(jq -r .step <<<"$L1")" = "implement" ] || failCase "log step, want implement: $L1"
[ "$(jq -r .risk <<<"$L1")" = "standard" ] || failCase "log risk, want standard: $L1"
[ "$(jq -r .tier <<<"$L1")" = "secondary" ] || failCase "log tier for implement standard, want secondary: $L1"
[ "$(jq -r .provider <<<"$L1")" = "qwen" ] || failCase "log provider must equal the routed agent, want qwen: $L1"
[ -n "$(jq -r .reason <<<"$L1")" ] || failCase "log reason must not be empty"
L2=$(sed -n 2p "$ROUTING_LOG")
[ "$(jq -r .tier <<<"$L2")" = "primary" ] || failCase "log tier for implement high, want primary: $L2"
[ "$(jq -r .provider <<<"$L2")" = "claude" ] || failCase "log provider for implement high, want claude: $L2"
[ "$(jq -r .risk <<<"$L2")" = "high" ] || failCase "log risk, want high: $L2"
L3=$(sed -n 3p "$ROUTING_LOG")
[ "$(jq -r .tier <<<"$L3")" = "owner" ] || failCase "log tier for merge, want owner: $L3"
[ "$(jq -r .provider <<<"$L3")" = "owner" ] || failCase "log provider for merge, want owner: $L3"
# Default log path: ~/.claude/routing-log.jsonl.
mkdir -p "$WORK/loghome/.claude"
(
  unset ROUTING_LOG
  HOME="$WORK/loghome" bash "$SCRIPT" spec --risk standard >/dev/null
) || failCase "route with ROUTING_LOG unset must succeed"
[ "$(wc -l <"$WORK/loghome/.claude/routing-log.jsonl" | tr -d ' ')" = "1" ] ||
  failCase "the default log path is \$HOME/.claude/routing-log.jsonl"

# --- 11. --author and --security are accepted and change nothing in stdout. ---
useMachineFile "$TEMPLATE"
for step in spec test-author implement security-review merge; do
  for risk in standard high; do
    routeOk "$step" --risk "$risk"
    BASE="$OUT"
    for extra in "--author claude" "--author codex" "--security" "--author codex --security"; do
      # shellcheck disable=SC2086  # extra is a fixed, space-separated flag list
      routeOk "$step" --risk "$risk" $extra
      [ "$OUT" = "$BASE" ] || failCase "$step --risk $risk $extra must print what $step --risk $risk prints ('$BASE'), got '$OUT'"
    done
  done
done
for risk in standard high; do
  routeOk review --risk "$risk" --author claude
  BASE="$OUT"
  for extra in "--author codex" "--author claude --security"; do
    # shellcheck disable=SC2086
    routeOk review --risk "$risk" $extra
    [ "$OUT" = "$BASE" ] || failCase "review --risk $risk $extra must print what review --author claude prints ('$BASE'), got '$OUT'"
  done
done

# --- 12. Negative input: exit 2, a message on stderr, no agent, no log line. ---
rm -f "$ROUTING_LOG"
BIG=$(head -c 5000 /dev/zero | tr '\0' a)
# expectReject <description> <args...>
expectReject() {
  local what="$1" before
  shift
  before=$(logCount)
  route "$@"
  [ "$RC" -eq 2 ] || failCase "$what: must exit 2 (got $RC, stdout '$OUT')"
  [ -n "$ERR" ] || failCase "$what: must explain on stderr"
  [ -z "$OUT" ] || failCase "$what: must print no agent (got '$OUT')"
  [ "$(logCount)" = "$before" ] || failCase "$what: must write no log line"
}
expectReject "an unknown step" bogus --risk standard
expectReject "a step with shell metacharacters" 'spec; rm -rf /' --risk standard
expectReject "a command substitution step" "\$(touch $WORK/pwned)" --risk standard
[ ! -e "$WORK/pwned" ] || failCase "a command substitution in the step must never run"
expectReject "a backtick step" "\`touch $WORK/pwned2\`" --risk standard
[ ! -e "$WORK/pwned2" ] || failCase "a backtick in the step must never run"
expectReject "a risk of medium" spec --risk medium
expectReject "a risk with metacharacters" spec --risk 'high; rm -rf /'
expectReject "a command substitution risk" spec --risk "\$(touch $WORK/pwned3)"
[ ! -e "$WORK/pwned3" ] || failCase "a command substitution in the risk must never run"
expectReject "a missing --risk" spec
expectReject "a --risk with no value" spec --risk
expectReject "an author with metacharacters" spec --risk standard --author 'claude; id'
expectReject "a command substitution author" spec --risk standard --author "\$(touch $WORK/pwned4)"
[ ! -e "$WORK/pwned4" ] || failCase "a command substitution in the author must never run"
expectReject "an unknown argument" spec --risk standard --bogus
expectReject "an oversized step" "$BIG" --risk standard
expectReject "an oversized risk" spec --risk "$BIG"
expectReject "an oversized author" spec --risk standard --author "$BIG"
[ "$(logCount)" = "0" ] || failCase "rejected calls must leave the log empty (got $(logCount))"

# --- 12b. HOME unset: no bogus root path for the machine file or the log. ---
# With HOME unset, ${HOME:-}/.claude/... collapses to /.claude/..., a path
# under the filesystem root. route.sh must not name or use it: it still exits
# 0 on the primary agent, says why, and never tries to write under /.claude.
# env -u HOME keeps every case off the real ~/.claude.
HOMELESS_ERR="$WORK/homeless-err"
HOMELESS_RC=0
HOMELESS_OUT=$(env -u HOME -u AGENT_TIER_ASSIGNMENTS_FILE ROUTING_LOG="$WORK/homeless-log.jsonl" \
  bash "$SCRIPT" implement --risk standard 2>"$HOMELESS_ERR") || HOMELESS_RC=$?
HOMELESS_P=$(printf '%s\n' "$HOMELESS_OUT" | sed -n 1p)
HOMELESS_REASON=$(printf '%s\n' "$HOMELESS_OUT" | sed -n 2p)
[ "$HOMELESS_RC" -eq 0 ] || failCase "HOME unset: route must exit 0 (got $HOMELESS_RC, stderr: $(cat "$HOMELESS_ERR"))"
[ "$HOMELESS_P" = "claude" ] || failCase "HOME unset: implement --risk standard must route to claude (got '$HOMELESS_P')"
case "$HOMELESS_REASON" in
  *"HOME is unset"*) ;;
  *) failCase "HOME unset: the reason must say 'HOME is unset' (got '$HOMELESS_REASON')" ;;
esac
case "$HOMELESS_REASON" in
  *"/.claude/agent-tier-assignments.json"*)
    failCase "HOME unset: the reason must not name the root path /.claude/agent-tier-assignments.json (got '$HOMELESS_REASON')" ;;
esac

# HOME and ROUTING_LOG both unset: no log write is attempted under /.claude.
HOMELESS_RC=0
HOMELESS_OUT=$(env -u HOME -u AGENT_TIER_ASSIGNMENTS_FILE -u ROUTING_LOG \
  bash "$SCRIPT" implement --risk standard 2>"$HOMELESS_ERR") || HOMELESS_RC=$?
HOMELESS_STDERR=$(cat "$HOMELESS_ERR")
[ "$HOMELESS_RC" -eq 0 ] || failCase "HOME and ROUTING_LOG unset: route must exit 0 (got $HOMELESS_RC, stderr: $HOMELESS_STDERR)"
[ "$(printf '%s\n' "$HOMELESS_OUT" | sed -n 1p)" = "claude" ] ||
  failCase "HOME and ROUTING_LOG unset: implement --risk standard must route to claude (got '$HOMELESS_OUT')"
case "$HOMELESS_STDERR" in
  *"/.claude"*) failCase "HOME and ROUTING_LOG unset: stderr must not mention /.claude (got '$HOMELESS_STDERR')" ;;
esac
case "$HOMELESS_STDERR" in
  *"could not append"*) failCase "HOME and ROUTING_LOG unset: route must not try to append a log under the root path (got '$HOMELESS_STDERR')" ;;
esac

# HOME set, AGENT_TIER_ASSIGNMENTS_FILE unset: $HOME/.claude/agent-tier-assignments.json
# still resolves, here assigning secondary work to qwen.
mkdir -p "$WORK/qwenhome/.claude"
printf '%s\n' '{"primary": {"agent": "claude"}, "secondary": {"agent": "qwen"}}' \
  >"$WORK/qwenhome/.claude/agent-tier-assignments.json"
QWENHOME_OUT=$(env -u AGENT_TIER_ASSIGNMENTS_FILE HOME="$WORK/qwenhome" ROUTING_LOG="$WORK/qwenhome-log.jsonl" \
  bash "$SCRIPT" implement --risk standard 2>/dev/null) ||
  failCase "HOME set to a temp dir: route must succeed"
[ "$(printf '%s\n' "$QWENHOME_OUT" | sed -n 1p)" = "qwen" ] ||
  failCase "HOME set, AGENT_TIER_ASSIGNMENTS_FILE unset: the default machine file must assign implement to qwen (got '$QWENHOME_OUT')"

# --- 13. route.sh never invokes quota-pace.sh and needs no quota file. ---
SANDBOX="$WORK/sandbox"
mkdir -p "$SANDBOX"
# Every enforce/*.sh comes along, so a file route.sh sources is in the sandbox;
# the quota-pace.sh copy is replaced by the stub below.
cp "$CLAUDE_HARNESS_ROOT"/enforce/*.sh "$STEPS" "$SANDBOX/"
MARKER="$WORK/quota-pace-was-called"
cat >"$SANDBOX/quota-pace.sh" <<EOF
#!/usr/bin/env bash
touch "$MARKER"
echo '{"providers": []}'
EOF
chmod +x "$SANDBOX/quota-pace.sh"
[ ! -e "$CLAUDE_QUOTA_FILE" ] || failCase "setup: the quota file must not exist"
useMachineFile "$TEMPLATE"
SCRIPT="$SANDBOX/route.sh"
expectRoute qwen implement --risk standard
expectRoute claude implement --risk high
expectRoute claude spec --risk standard
expectRoute owner merge --risk standard
[ ! -e "$MARKER" ] || failCase "route.sh must never invoke quota-pace.sh"
# Back to the checkout's route.sh for the cases below.
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/route.sh"

# --- 14. A secondary agent name with control characters cannot split the reason. ---
# The machine file's secondary.agent is "gem<LF>ini<BEL>": stdout must stay
# exactly two lines with no control character, and the log line must be JSON
# whose reason is that same single line.
writeMachineFile '{"primary": {"agent": "claude"}, "secondary": {"agent": "gem\nini\u0007"}}'
rm -f "$ROUTING_LOG"
route implement --risk standard
[ "$RC" -eq 0 ] || failCase "control-character secondary: route must exit 0 (got $RC, stderr: $ERR)"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "2" ] ||
  failCase "control-character secondary: stdout must be exactly two lines (got '$OUT')"
[ "$P" = "claude" ] || failCase "control-character secondary: line 1 must be claude (got '$P')"
[ -n "$REASON" ] || failCase "control-character secondary: line 2 must carry a reason"
if printf '%s' "$REASON" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  failCase "control-character secondary: the reason must hold no control character (got '$REASON')"
fi
[ "$(logCount)" = "1" ] || failCase "control-character secondary: want one log line (got $(logCount))"
CTRL_LINE=$(sed -n 1p "$ROUTING_LOG")
jq -e . >/dev/null 2>&1 <<<"$CTRL_LINE" || failCase "control-character secondary: log line must be JSON: $CTRL_LINE"
[ "$(jq -r .reason <<<"$CTRL_LINE")" = "$REASON" ] ||
  failCase "control-character secondary: log reason must equal the stdout reason line '$REASON' (log: $CTRL_LINE)"

# --- 15. A repeated --risk is a usage error; a single --risk still routes. ---
useMachineFile "$TEMPLATE"
rm -f "$ROUTING_LOG"
expectReject "a repeated --risk (standard then high)" spec --risk standard --risk high
expectReject "a repeated --risk on implement (high then standard)" implement --risk high --risk standard
expectReject "a repeated --risk around --author" implement --risk standard --author claude --risk high
[ "$(logCount)" = "0" ] || failCase "repeated --risk calls must leave the log empty (got $(logCount))"
expectRoute claude spec --risk standard
expectRoute qwen implement --risk standard
expectRoute claude implement --risk high

# --- 16. HOME unset: merge's reason does not talk about a primary agent. ---
# routeHomeless <args...>: runs route.sh with HOME, CLAUDE_HOME and
# AGENT_TIER_ASSIGNMENTS_FILE unset; sets HL_RC, HL_OUT, HL_P, HL_REASON.
routeHomeless() {
  HL_RC=0
  HL_OUT=$(env -u HOME -u CLAUDE_HOME -u AGENT_TIER_ASSIGNMENTS_FILE ROUTING_LOG="$WORK/homeless16-log.jsonl" \
    bash "$SCRIPT" "$@" 2>"$WORK/homeless16-err") || HL_RC=$?
  HL_P=$(printf '%s\n' "$HL_OUT" | sed -n 1p)
  HL_REASON=$(printf '%s\n' "$HL_OUT" | sed -n 2p)
  [ "$HL_RC" -eq 0 ] || failCase "HOME unset, route $*: must exit 0 (got $HL_RC, stderr: $(cat "$WORK/homeless16-err"))"
}
routeHomeless merge --risk standard
[ "$HL_P" = "owner" ] || failCase "HOME unset: merge --risk standard must print owner (got '$HL_P')"
case "$HL_REASON" in
  *"primary agent"*) failCase "HOME unset: merge's reason must not mention 'primary agent', merge is the owner's (got '$HL_REASON')" ;;
esac
for step in spec implement; do
  routeHomeless "$step" --risk standard
  [ "$HL_P" = "claude" ] || failCase "HOME unset: $step --risk standard must print claude (got '$HL_P')"
  case "$HL_REASON" in
    *"HOME is unset"*) ;;
    *) failCase "HOME unset: $step --risk standard reason must say 'HOME is unset' (got '$HL_REASON')" ;;
  esac
done

# --- 17. CLAUDE_HOME names the Claude config directory for the machine file. ---
# Order: AGENT_TIER_ASSIGNMENTS_FILE, then $CLAUDE_HOME/agent-tier-assignments.json,
# then $HOME/.claude/agent-tier-assignments.json. Each file gives spec a
# different primary agent, so line 1 shows which file was read.
mkdir -p "$WORK/chome" "$WORK/chome-home/.claude"
printf '%s\n' '{"primary": {"agent": "qwen"}}' >"$WORK/chome/agent-tier-assignments.json"
printf '%s\n' '{"primary": {"agent": "claude"}}' >"$WORK/chome-home/.claude/agent-tier-assignments.json"
printf '%s\n' '{"primary": {"agent": "claude"}}' >"$WORK/chome-explicit.json"
# routeClaudeHome <env assignments...> -- <args...>: runs route.sh under
# env -u AGENT_TIER_ASSIGNMENTS_FILE -u CLAUDE_HOME -u HOME plus the given
# assignments; sets CH_RC, CH_OUT, CH_P, CH_REASON.
routeClaudeHome() {
  local assigns=()
  while [ "$1" != "--" ]; do
    assigns+=("$1")
    shift
  done
  shift
  CH_RC=0
  CH_OUT=$(env -u AGENT_TIER_ASSIGNMENTS_FILE -u CLAUDE_HOME -u HOME ROUTING_LOG="$WORK/chome-log.jsonl" \
    "${assigns[@]}" bash "$SCRIPT" "$@" 2>"$WORK/chome-err") || CH_RC=$?
  CH_P=$(printf '%s\n' "$CH_OUT" | sed -n 1p)
  CH_REASON=$(printf '%s\n' "$CH_OUT" | sed -n 2p)
  [ "$CH_RC" -eq 0 ] || failCase "CLAUDE_HOME, route $*: must exit 0 (got $CH_RC, stderr: $(cat "$WORK/chome-err"))"
}
# CLAUDE_HOME set, HOME set: the CLAUDE_HOME file wins over $HOME/.claude.
routeClaudeHome CLAUDE_HOME="$WORK/chome" HOME="$WORK/chome-home" -- spec --risk standard
[ "$CH_P" = "qwen" ] ||
  failCase "CLAUDE_HOME set: the machine file must be \$CLAUDE_HOME/agent-tier-assignments.json, ahead of \$HOME/.claude (got '$CH_P': $CH_REASON)"
# CLAUDE_HOME set, HOME unset: the CLAUDE_HOME file alone still resolves.
routeClaudeHome CLAUDE_HOME="$WORK/chome" -- spec --risk standard
[ "$CH_P" = "qwen" ] ||
  failCase "CLAUDE_HOME set, HOME unset: the machine file must be \$CLAUDE_HOME/agent-tier-assignments.json (got '$CH_P': $CH_REASON)"
# AGENT_TIER_ASSIGNMENTS_FILE still wins over CLAUDE_HOME.
routeClaudeHome AGENT_TIER_ASSIGNMENTS_FILE="$WORK/chome-explicit.json" CLAUDE_HOME="$WORK/chome" HOME="$WORK/chome-home" \
  -- spec --risk standard
[ "$CH_P" = "claude" ] ||
  failCase "AGENT_TIER_ASSIGNMENTS_FILE must win over CLAUDE_HOME (got '$CH_P': $CH_REASON)"
# HOME unset, CLAUDE_HOME holding a qwen secondary: implement standard is qwen
# and the reason does not claim HOME is unset as the cause.
mkdir -p "$WORK/chome-qwen"
printf '%s\n' '{"primary": {"agent": "claude"}, "secondary": {"agent": "qwen"}}' \
  >"$WORK/chome-qwen/agent-tier-assignments.json"
routeClaudeHome CLAUDE_HOME="$WORK/chome-qwen" -- implement --risk standard
[ "$CH_P" = "qwen" ] ||
  failCase "HOME unset, CLAUDE_HOME set: implement --risk standard must use the CLAUDE_HOME machine file's qwen secondary (got '$CH_P': $CH_REASON)"
case "$CH_REASON" in
  *"HOME is unset"*) failCase "HOME unset, CLAUDE_HOME set: the reason must not say 'HOME is unset' (got '$CH_REASON')" ;;
esac

# --- 18. resolve-machine-file.sh is shellcheck-clean at warning level. ---
if command -v shellcheck >/dev/null 2>&1; then
  SC_OUT=$(cd "$CLAUDE_HARNESS_ROOT/enforce" && shellcheck -x -S warning resolve-machine-file.sh 2>&1) ||
    failCase "resolve-machine-file.sh must pass shellcheck -x -S warning: $SC_OUT"
else
  echo "SKIP: shellcheck is not installed; resolve-machine-file.sh lint case not run"
fi

# --- 19. An invalid machine file at a control-character path cannot split the reason. ---
# The machine file sits in a directory named "bad<LF>dir<BEL>" and is not JSON.
# stdout must stay exactly two lines with no control character in the reason,
# the log line must be JSON whose reason is that same line, and the stderr
# warning must hold no control character but its own trailing newline.
CTRL_DIR="$WORK/bad"$'\n'"dir"$'\a'
mkdir -p "$CTRL_DIR"
printf 'not json {\n' >"$CTRL_DIR/machine.json"
useMachineFile "$CTRL_DIR/machine.json"
rm -f "$ROUTING_LOG"
route spec --risk standard
[ "$RC" -eq 0 ] || failCase "control-character invalid machine file path: route must exit 0 (got $RC, stderr: $ERR)"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "2" ] ||
  failCase "control-character invalid machine file path: stdout must be exactly two lines (got '$OUT')"
[ "$P" = "claude" ] || failCase "control-character invalid machine file path: line 1 must be claude (got '$P')"
[ -n "$REASON" ] || failCase "control-character invalid machine file path: line 2 must carry a reason"
if printf '%s' "$REASON" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  failCase "control-character invalid machine file path: the reason must hold no control character (got '$REASON')"
fi
[ "$(logCount)" = "1" ] || failCase "control-character invalid machine file path: want one log line (got $(logCount))"
CTRL_PATH_LINE=$(sed -n 1p "$ROUTING_LOG")
jq -e . >/dev/null 2>&1 <<<"$CTRL_PATH_LINE" ||
  failCase "control-character invalid machine file path: log line must be JSON: $CTRL_PATH_LINE"
[ "$(jq -r .reason <<<"$CTRL_PATH_LINE")" = "$REASON" ] ||
  failCase "control-character invalid machine file path: log reason must equal the stdout reason line '$REASON' (log: $CTRL_PATH_LINE)"
# ERR is captured with $(...), which drops the trailing newline; any control
# character left is inside the warning.
[ -n "$ERR" ] || failCase "control-character invalid machine file path: want the invalid-JSON warning on stderr"
if printf '%s' "$ERR" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  failCase "control-character invalid machine file path: the stderr warning must hold no control character (got '$ERR')"
fi

# --- 20. A machine file path that looks like an echo flag is still the path. ---
# routeInDir <dir> <machine file value> <args...>: runs route.sh from dir with
# AGENT_TIER_ASSIGNMENTS_FILE set to the value and CLAUDE_HOME and HOME unset;
# sets DIR_RC, DIR_OUT, DIR_P, DIR_REASON.
routeInDir() {
  local dir="$1" value="$2"
  shift 2
  DIR_RC=0
  DIR_OUT=$(cd "$dir" && env -u CLAUDE_HOME -u HOME AGENT_TIER_ASSIGNMENTS_FILE="$value" \
    ROUTING_LOG="$WORK/dashpath-log.jsonl" bash "$SCRIPT" "$@" 2>"$WORK/dashpath-err") || DIR_RC=$?
  DIR_P=$(printf '%s\n' "$DIR_OUT" | sed -n 1p)
  DIR_REASON=$(printf '%s\n' "$DIR_OUT" | sed -n 2p)
  [ "$DIR_RC" -eq 0 ] || failCase "machine file '$value', route $*: must exit 0 (got $DIR_RC, stderr: $(cat "$WORK/dashpath-err"))"
}
mkdir -p "$WORK/dashpath"
for flagName in -n -e; do
  printf '%s\n' '{"primary": {"agent": "claude"}, "secondary": {"agent": "qwen"}}' >"$WORK/dashpath/$flagName"
  routeInDir "$WORK/dashpath" "$flagName" implement --risk standard
  [ "$DIR_P" = "qwen" ] ||
    failCase "AGENT_TIER_ASSIGNMENTS_FILE=$flagName: implement --risk standard must use that file's qwen secondary (got '$DIR_P': $DIR_REASON)"
  case "$DIR_REASON" in
    *"HOME is unset"*) failCase "AGENT_TIER_ASSIGNMENTS_FILE=$flagName: the reason must not say 'HOME is unset' (got '$DIR_REASON')" ;;
  esac
done

# --- 21. A backslash in the machine file path is kept as is. ---
# The directory name holds backslash sequences (\n, \c) that echo -e or
# xpg_echo would rewrite; the file must still be read.
BS_DIR="$WORK/"'a\nb\c'
mkdir -p "$BS_DIR"
printf '%s\n' '{"primary": {"agent": "claude"}, "secondary": {"agent": "qwen"}}' >"$BS_DIR/machine.json"
useMachineFile "$BS_DIR/machine.json"
expectRoute qwen implement --risk standard
case "$REASON" in
  *"no machine file"*) failCase "backslash path: the machine file must be found (got '$REASON')" ;;
esac

# --- 22. The owner tier keeps the machine file note (IAN-712). ---
# merge is the owner's whatever the machine file says, but the reason still
# reports a missing or invalid machine file, or an unset HOME, and never talks
# about a primary agent.
# expectOwnerNote <what> <note>: the last call printed owner, its reason holds
# the note, and it does not say 'primary agent'.
expectOwnerNote() {
  [ "$P" = "owner" ] || failCase "$1: merge --risk standard must print owner (got '$P')"
  case "$REASON" in
    *"$2"*) ;;
    *) failCase "$1: merge's reason must keep the machine file note '$2' (got '$REASON')" ;;
  esac
  case "$REASON" in
    *"primary agent"*) failCase "$1: merge's reason must not mention 'primary agent' (got '$REASON')" ;;
  esac
}
useMachineFile "$WORK/no-such-machine-file.json"
expectRoute owner merge --risk standard
expectOwnerNote "no machine file" "no machine file found"
useMachineFile "$WORK/bad.json"
expectRoute owner merge --risk standard
expectOwnerNote "invalid machine file" "not valid JSON"
# HOME, CLAUDE_HOME and AGENT_TIER_ASSIGNMENTS_FILE all unset.
routeHomeless merge --risk standard
P="$HL_P"
REASON="$HL_REASON"
expectOwnerNote "HOME unset" "HOME is unset"
for step in spec implement; do
  routeHomeless "$step" --risk standard
  [ "$HL_P" = "claude" ] || failCase "HOME unset (IAN-712): $step --risk standard must print claude (got '$HL_P')"
  case "$HL_REASON" in
    *"HOME is unset"*) ;;
    *) failCase "HOME unset (IAN-712): $step --risk standard reason must say 'HOME is unset' (got '$HL_REASON')" ;;
  esac
done

# --- 23. The default log path honors CLAUDE_HOME (IAN-712). ---
# Order: ROUTING_LOG, then $CLAUDE_HOME/routing-log.jsonl, then
# $HOME/.claude/routing-log.jsonl. The machine file is the template, so the
# CLAUDE_HOME machine file default plays no part.
mkdir -p "$WORK/logch1" "$WORK/logch1-home/.claude" "$WORK/logch2" "$WORK/logch3"
# routeLogEnv <env assignments...> -- <args...>: runs route.sh under
# env -u ROUTING_LOG -u CLAUDE_HOME -u HOME with the template machine file plus
# the given assignments; sets LG_RC and LG_ERR.
routeLogEnv() {
  local assigns=()
  while [ "$1" != "--" ]; do
    assigns[${#assigns[@]}]="$1"
    shift
  done
  shift
  LG_RC=0
  env -u ROUTING_LOG -u CLAUDE_HOME -u HOME AGENT_TIER_ASSIGNMENTS_FILE="$TEMPLATE" ${assigns[@]+"${assigns[@]}"} \
    bash "$SCRIPT" "$@" >/dev/null 2>"$WORK/logch-err" || LG_RC=$?
  LG_ERR=$(cat "$WORK/logch-err")
  [ "$LG_RC" -eq 0 ] || failCase "log path, route $*: must exit 0 (got $LG_RC, stderr: $LG_ERR)"
}
# lineCount <file>: lines in the file, 0 when it does not exist.
lineCount() {
  if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi
}
# CLAUDE_HOME and HOME set, ROUTING_LOG unset: the CLAUDE_HOME log gets one line.
routeLogEnv CLAUDE_HOME="$WORK/logch1" HOME="$WORK/logch1-home" -- spec --risk standard
[ "$(lineCount "$WORK/logch1/routing-log.jsonl")" = "1" ] ||
  failCase "ROUTING_LOG unset, CLAUDE_HOME set: one JSON line must go to \$CLAUDE_HOME/routing-log.jsonl (got $(lineCount "$WORK/logch1/routing-log.jsonl") lines)"
jq -e '.step == "spec"' "$WORK/logch1/routing-log.jsonl" >/dev/null 2>&1 ||
  failCase "ROUTING_LOG unset, CLAUDE_HOME set: the CLAUDE_HOME log line must be JSON for step spec ($(cat "$WORK/logch1/routing-log.jsonl" 2>/dev/null))"
[ "$(lineCount "$WORK/logch1-home/.claude/routing-log.jsonl")" = "0" ] ||
  failCase "ROUTING_LOG unset, CLAUDE_HOME set: CLAUDE_HOME must win over \$HOME/.claude/routing-log.jsonl"
# ROUTING_LOG wins over CLAUDE_HOME.
routeLogEnv ROUTING_LOG="$WORK/logch2-explicit.jsonl" CLAUDE_HOME="$WORK/logch2" HOME="$WORK/logch1-home" \
  -- spec --risk standard
[ "$(lineCount "$WORK/logch2-explicit.jsonl")" = "1" ] || failCase "ROUTING_LOG must win over CLAUDE_HOME (ROUTING_LOG file has $(lineCount "$WORK/logch2-explicit.jsonl") lines)"
[ "$(lineCount "$WORK/logch2/routing-log.jsonl")" = "0" ] || failCase "ROUTING_LOG set: nothing may go to \$CLAUDE_HOME/routing-log.jsonl"
# HOME unset, CLAUDE_HOME set: the CLAUDE_HOME log, with no warning.
routeLogEnv CLAUDE_HOME="$WORK/logch3" -- spec --risk standard
[ "$(lineCount "$WORK/logch3/routing-log.jsonl")" = "1" ] ||
  failCase "HOME and ROUTING_LOG unset, CLAUDE_HOME set: one line must go to \$CLAUDE_HOME/routing-log.jsonl (got $(lineCount "$WORK/logch3/routing-log.jsonl") lines)"
[ -z "$LG_ERR" ] || failCase "HOME and ROUTING_LOG unset, CLAUDE_HOME set: stderr must be empty (got '$LG_ERR')"
# Control: ROUTING_LOG, CLAUDE_HOME and HOME all unset logs nothing and warns of no failed append.
routeLogEnv -- spec --risk standard
case "$LG_ERR" in
  *"could not append"* | *"/.claude"*) failCase "ROUTING_LOG, CLAUDE_HOME and HOME unset: no log write may be tried (stderr: '$LG_ERR')" ;;
esac

echo "PASS: route"
