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

echo "PASS: route"
