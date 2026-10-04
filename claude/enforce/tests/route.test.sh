#!/usr/bin/env bash
# Covers: enforce/route.sh
# route.test.sh: verifies the step router behind quota-aware routing (IAN-603).
# route.sh <step> --risk <high|standard> [--author <claude|codex>] [--security]
# prints the provider on line 1 (claude, codex or owner) and a one-line reason
# on line 2, and appends one JSON line to $ROUTING_LOG. Every case writes its
# own quota file in a temp directory through CLAUDE_QUOTA_FILE and pins the
# clock with QUOTA_NOW, so no case reads the live ~/.claude/quota.json.
#
# Pace ratios are built from one snapshot taken at NOW, so with a window of W
# days and L days left (E = W - L days elapsed):
#   burn = used / E, budget = (100 - used) / L, ratio = used * L / ((100 - used) * E)
# Presets, written as used:windowDays:secondsLeft (ratio worked by hand, and
# re-checked against quota-pace.sh report --json in the setup section):
#   R01   20:7:172800     E=5 L=2   20*2/(80*5)  = 0.10
#   R05   55:7:172800     E=5 L=2   55*2/(45*5)  = 0.49
#   R12   75:7:172800     E=5 L=2   75*2/(25*5)  = 1.20 exactly
#   R13   76.5:7:172800   E=5 L=2   76.5*2/(23.5*5) = 1.30
#   R15   79:7:172800     E=5 L=2   79*2/(21*5)  = 1.50
#   NULLR 1:7:603000      30 minutes into the window: burn insufficient, ratio null, not exhausted
#   EXH   90:366:86400    E=365 L=1  ratio 0.02 but 90% used, so exhausted by the bucket rule alone
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/route.sh"
PACE="$CLAUDE_HARNESS_ROOT/enforce/quota-pace.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_QUOTA_FILE="$WORK/quota.json"
export ROUTING_LOG="$WORK/routing-log.jsonl"
NOW=1790960400
export QUOTA_NOW=$NOW

R01="20:7:172800"
R05="55:7:172800"
R12="75:7:172800"
R13="76.5:7:172800"
R15="79:7:172800"
NULLR="1:7:603000"
EXH="90:366:86400"

failCase() {
  echo "FAIL: $1"
  exit 1
}

# writeQuota <claude preset> <codex preset>: writes the quota file with one
# bucket per provider, each holding one snapshot taken at NOW.
writeQuota() {
  jq -n --argjson now "$NOW" --arg c "$1" --arg x "$2" '
    def b($s; $p): ($s | split(":")) as $f
      | {provider: $p,
         resetsAt: (($now + ($f[2] | tonumber)) | todate),
         windowDays: ($f[1] | tonumber),
         snapshots: [{at: ($now | todate), usedPct: ($f[0] | tonumber), source: "owner"}]};
    {buckets: {claude: b($c; "claude"), codex: b($x; "codex")}}' >"$CLAUDE_QUOTA_FILE"
}

# setPair <default provider> <default preset> <other preset>: writes the quota
# file so the step's default provider and the other one carry those presets.
setPair() {
  if [ "$1" = claude ]; then writeQuota "$2" "$3"; else writeQuota "$3" "$2"; fi
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

# routeOk <args...>: runs the router and fails unless it exited 0 with a
# provider on line 1 and a reason on line 2.
routeOk() {
  route "$@"
  [ "$RC" -eq 0 ] || failCase "route $* exited $RC (stderr: $ERR)"
  case "$P" in claude | codex | owner) ;; *) failCase "route $*: line 1 must be claude, codex or owner (got '$P')" ;; esac
  [ -n "$REASON" ] || failCase "route $*: line 2 must carry a reason"
}

# expectRoute <want> <args...>: routeOk, then line 1 must equal want.
expectRoute() {
  local want="$1"
  shift
  routeOk "$@"
  [ "$P" = "$want" ] || failCase "route $*: want $want, got $P ($REASON)"
}

logCount() {
  if [ -f "$ROUTING_LOG" ]; then wc -l <"$ROUTING_LOG" | tr -d ' '; else echo 0; fi
}

# ratioOf <provider>: the provider's pace ratio per quota-pace.sh.
ratioOf() {
  bash "$PACE" report --json | jq -r --arg p "$1" '.providers[] | select(.provider == $p) | .paceRatio'
}
exhaustedOf() {
  bash "$PACE" report --json | jq -r --arg p "$1" '.providers[] | select(.provider == $p) | .exhausted'
}

# --- 0. Setup: the presets give the ratios the cases below rely on. ---
for pair in "$R01=0.1" "$R05=0.49" "$R12=1.2" "$R13=1.3" "$R15=1.5" "$NULLR=null" "$EXH=0.02"; do
  writeQuota "${pair%%=*}" "${pair%%=*}"
  [ "$(ratioOf claude)" = "${pair#*=}" ] || failCase "setup: preset ${pair%%=*} must give ratio ${pair#*=}, got $(ratioOf claude)"
done
writeQuota "$EXH" "$EXH"
[ "$(exhaustedOf claude)" = "true" ] || failCase "setup: EXH must read exhausted"
writeQuota "$NULLR" "$NULLR"
[ "$(exhaustedOf claude)" = "false" ] || failCase "setup: NULLR must not read exhausted"
writeQuota "$R13" "$R13"
[ "$(exhaustedOf claude)" = "false" ] || failCase "setup: R13 must not read exhausted"

# --- 1. Role defaults, both ratios about 0.5. ---
writeQuota "$R05" "$R05"
expectRoute claude spec --risk standard
expectRoute claude architecture --risk standard
expectRoute codex test-author --risk standard
expectRoute codex test-author --risk high
expectRoute codex implement --risk standard
expectRoute claude implement --risk high
expectRoute claude security-review --risk high
expectRoute claude security-review --risk standard
case "$REASON" in *fable*) ;; *) failCase "security-review reason must name the model fable (got: $REASON)" ;; esac
expectRoute owner merge --risk standard
expectRoute owner merge --risk high
# The provider alone is on line 1: no extra words.
routeOk spec --risk standard
[ "$P" = "claude" ] || failCase "line 1 must be the bare provider (got '$P')"

# --- 2. Review is always cross-model. ---
for c in "$R05" "$R13" "$EXH" "$NULLR"; do
  for x in "$R05" "$R13" "$EXH" "$NULLR"; do
    writeQuota "$c" "$x"
    for risk in standard high; do
      expectRoute codex review --risk "$risk" --author claude
      expectRoute claude review --risk "$risk" --author codex
    done
  done
done
rm -f "$ROUTING_LOG"
writeQuota "$R05" "$R05"
route review --risk standard
[ "$RC" -eq 2 ] || failCase "review without --author must exit 2 (got $RC)"
[ -n "$ERR" ] || failCase "review without --author must explain on stderr"
[ -z "$OUT" ] || failCase "review without --author must print no provider (got '$OUT')"
[ "$(logCount)" = "0" ] || failCase "review without --author must write no log line"

# --- 3. Pace shift: above 1.2 and the other provider lower. ---
# step:default provider:other provider
for spec in spec:claude:codex architecture:claude:codex test-author:codex:claude implement:codex:claude; do
  step="${spec%%:*}"
  rest="${spec#*:}"
  def="${rest%%:*}"
  oth="${rest#*:}"
  setPair "$def" "$R13" "$R05"
  expectRoute "$oth" "$step" --risk standard
  setPair "$def" "$R12" "$R05"
  expectRoute "$def" "$step" --risk standard
  setPair "$def" "$R05" "$R05"
  expectRoute "$def" "$step" --risk standard
  # The other provider's ratio is null (burn unjudgeable): no move.
  setPair "$def" "$R13" "$NULLR"
  expectRoute "$def" "$step" --risk standard
  # The other provider is not lower: equal, and higher.
  setPair "$def" "$R13" "$R13"
  expectRoute "$def" "$step" --risk standard
  setPair "$def" "$R13" "$R15"
  expectRoute "$def" "$step" --risk standard
  # The default provider is the one under the pace: no move.
  setPair "$def" "$R05" "$R13"
  expectRoute "$def" "$step" --risk standard
  setPair "$def" "$R01" "$R15"
  expectRoute "$def" "$step" --risk standard
  # A step that moved says why.
  setPair "$def" "$R13" "$R05"
  routeOk "$step" --risk standard
  [ -n "$REASON" ] || failCase "$step moved without a reason"
done

# --- 4. Exhaustion: 90% used moves a routable step; pinned steps never move. ---
for spec in spec:claude:codex architecture:claude:codex test-author:codex:claude implement:codex:claude; do
  step="${spec%%:*}"
  rest="${spec#*:}"
  def="${rest%%:*}"
  oth="${rest#*:}"
  # Ratio 0.02 on the default: only the exhaustion rule can move it.
  setPair "$def" "$EXH" "$R05"
  expectRoute "$oth" "$step" --risk standard
  setPair "$def" "$EXH" "$R15"
  expectRoute "$oth" "$step" --risk standard
  setPair "$def" "$EXH" "$NULLR"
  expectRoute "$oth" "$step" --risk standard
  # Both exhausted: nowhere to go.
  setPair "$def" "$EXH" "$EXH"
  expectRoute "$def" "$step" --risk standard
done
# Exhausted just under the line is not exhausted: 75% used, ratio 1.2, stays.
setPair claude "$R12" "$R05"
expectRoute claude spec --risk standard

# --- 5. Pinned steps never move under any input. ---
for c in "$R01" "$R05" "$R13" "$EXH" "$NULLR"; do
  for x in "$R01" "$R05" "$R13" "$EXH" "$NULLR"; do
    writeQuota "$c" "$x"
    for risk in standard high; do
      expectRoute claude security-review --risk "$risk"
      case "$REASON" in *fable*) ;; *) failCase "security-review reason must name fable ($c / $x)" ;; esac
      expectRoute owner merge --risk "$risk"
    done
    expectRoute claude implement --risk high
    expectRoute claude implement --risk high --security
    expectRoute claude security-review --risk high --security
  done
done
rm -f "$CLAUDE_QUOTA_FILE"
expectRoute claude security-review --risk high
expectRoute claude implement --risk high
expectRoute owner merge --risk standard
echo 'not json' >"$CLAUDE_QUOTA_FILE"
expectRoute claude security-review --risk high
expectRoute claude implement --risk high
expectRoute owner merge --risk standard

# --- 6. Missing or unreadable quota file: role defaults, and still logged. ---
for state in missing garbage empty-buckets; do
  case "$state" in
    missing) rm -f "$CLAUDE_QUOTA_FILE" ;;
    garbage) echo 'not json' >"$CLAUDE_QUOTA_FILE" ;;
    empty-buckets) echo '{"buckets":{}}' >"$CLAUDE_QUOTA_FILE" ;;
  esac
  rm -f "$ROUTING_LOG"
  expectRoute claude spec --risk standard
  case "$REASON" in *"quota unavailable"*) ;; *) failCase "$state: reason must contain 'quota unavailable' (got: $REASON)" ;; esac
  [ "$(logCount)" = "1" ] || failCase "$state: a call without quota data must still write one log line"
  expectRoute claude architecture --risk standard
  expectRoute codex test-author --risk standard
  expectRoute codex implement --risk standard
  expectRoute codex review --risk standard --author claude
  expectRoute claude review --risk standard --author codex
  case "$REASON" in *"quota unavailable"*) ;; *) failCase "$state: a review reason must also say 'quota unavailable' (got: $REASON)" ;; esac
  expectRoute claude security-review --risk high
  case "$REASON" in *"quota unavailable"*) ;; *) failCase "$state: a pinned reason must also say 'quota unavailable' (got: $REASON)" ;; esac
  rm -f "$ROUTING_LOG"; expectRoute claude spec --risk standard; expectRoute claude architecture --risk standard
  expectRoute codex test-author --risk standard; expectRoute codex implement --risk standard
  expectRoute codex review --risk standard --author claude; expectRoute claude review --risk standard --author codex
  [ "$(logCount)" = "6" ] || failCase "$state: want 6 log lines after 6 calls, got $(logCount)"
  jq -e . "$ROUTING_LOG" >/dev/null || failCase "$state: every log line must parse"
  [ "$(jq -s '[.[] | select((.ratios | type) == "object" and (.ratios | has("claude")) and (.ratios | has("codex")))] | length' "$ROUTING_LOG")" = "6" ] ||
    failCase "$state: the log must carry a ratios object with claude and codex even without quota data"
done

# An exhausted default with no data at all for the other provider stays put:
# moving work to a provider the report knows nothing about is a guess (PR 3 review).
jq -n --argjson now "$NOW" '{buckets: {claude: {provider: "claude", resetsAt: (($now + 86400) | todate), windowDays: 366,
  snapshots: [{at: ($now | todate), usedPct: 90, source: "owner"}]}}}' >"$CLAUDE_QUOTA_FILE"
expectRoute claude spec --risk standard

# --- 7. The log: one JSON line per successful call. ---
rm -f "$ROUTING_LOG"
writeQuota "$R13" "$R05"
routeOk spec --risk standard
[ "$(logCount)" = "1" ] || failCase "one call must append exactly one line (got $(logCount))"
routeOk implement --risk high --security
routeOk review --risk standard --author claude
[ "$(logCount)" = "3" ] || failCase "three calls must append three lines (got $(logCount))"
jq -e . "$ROUTING_LOG" >/dev/null || failCase "every log line must parse with jq"
KEYS='has("ts") and has("step") and has("risk") and has("author") and has("security") and has("ratios") and has("provider") and has("reason")'
[ "$(jq -s "[.[] | select($KEYS and (.ratios | type) == \"object\" and (.ratios | has(\"claude\")) and (.ratios | has(\"codex\")))] | length" "$ROUTING_LOG")" = "3" ] ||
  failCase "every log line needs ts, step, risk, author, security, ratios{claude,codex}, provider, reason"
# The first line (spec: claude 1.3 vs codex 0.49 moves to codex) records what happened.
L1=$(sed -n 1p "$ROUTING_LOG")
[ "$(jq -r .step <<<"$L1")" = "spec" ] || failCase "log step"
[ "$(jq -r .risk <<<"$L1")" = "standard" ] || failCase "log risk"
[ "$(jq -r .provider <<<"$L1")" = "codex" ] || failCase "log provider must equal the routed provider"
[ "$(jq -r .security <<<"$L1")" = "false" ] || failCase "log security must be false without --security"
[ "$(jq -r '.ratios.claude' <<<"$L1")" = "1.3" ] || failCase "log ratios.claude, want 1.3"
[ "$(jq -r '.ratios.codex' <<<"$L1")" = "0.49" ] || failCase "log ratios.codex, want 0.49"
[ -n "$(jq -r .reason <<<"$L1")" ] || failCase "log reason must not be empty"
[ -n "$(jq -r .ts <<<"$L1")" ] || failCase "log ts must not be empty"
L2=$(sed -n 2p "$ROUTING_LOG")
[ "$(jq -r .security <<<"$L2")" = "true" ] || failCase "log security must be true with --security"
[ "$(jq -r .provider <<<"$L2")" = "claude" ] || failCase "log provider for pinned implement --risk high"
L3=$(sed -n 3p "$ROUTING_LOG")
[ "$(jq -r .author <<<"$L3")" = "claude" ] || failCase "log author must record --author"
[ "$(jq -r .provider <<<"$L3")" = "codex" ] || failCase "log provider for review of claude work"
# Default log path: ~/.claude/routing-log.jsonl.
mkdir -p "$WORK/home/.claude"
(
  unset ROUTING_LOG
  HOME="$WORK/home" bash "$SCRIPT" spec --risk standard >/dev/null
) || failCase "route with ROUTING_LOG unset must succeed"
[ "$(wc -l <"$WORK/home/.claude/routing-log.jsonl" | tr -d ' ')" = "1" ] || failCase "the default log path is \$HOME/.claude/routing-log.jsonl"

# --- 8. The answer is never skip and never empty. ---
# grid: every step at both risks (review at both authors) under the current quota file.
grid() {
  local step risk
  for step in spec architecture test-author implement security-review review merge; do
    for risk in standard high; do
      if [ "$step" = review ]; then
        routeOk "$step" --risk "$risk" --author claude
        routeOk "$step" --risk "$risk" --author codex
      else
        routeOk "$step" --risk "$risk"
      fi
      [ "$P" != skip ] || failCase "route $step: never skip"
    done
  done
}
for c in "$R05" "$R13" "$EXH" "$NULLR"; do
  for x in "$R05" "$R13" "$EXH" "$NULLR"; do
    writeQuota "$c" "$x"
    grid
  done
done
rm -f "$CLAUDE_QUOTA_FILE"
grid
echo 'not json' >"$CLAUDE_QUOTA_FILE"
grid

# --- 9. Negative input: exit 2, a message on stderr, no provider, no log line. ---
writeQuota "$R05" "$R05"
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
  [ -z "$OUT" ] || failCase "$what: must print no provider (got '$OUT')"
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
expectReject "a missing --risk" spec
expectReject "a --risk with no value" spec --risk
expectReject "an unknown author" review --risk standard --author gemini
expectReject "an author with metacharacters" spec --risk standard --author 'claude; id'
expectReject "an oversized step" "$BIG" --risk standard
expectReject "an oversized risk" spec --risk "$BIG"
expectReject "a review with no author" review --risk standard
[ "$(logCount)" = "0" ] || failCase "rejected calls must leave the log empty (got $(logCount))"

echo "PASS: route"
