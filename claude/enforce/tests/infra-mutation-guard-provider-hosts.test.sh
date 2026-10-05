#!/usr/bin/env bash
# Covers: hook:infra-mutation-guard
# Verifies that a malformed .enforce.json provider_hosts value fails closed:
# a string where a list belongs, and a list holding a number, each make
# infra-mutation-guard.sh deny a non-read HTTP call to a provider host, with a
# reason naming .enforce.json. A well-formed list is the control: the same
# command then denies for the provider host (not for a config error), and a
# read of an unlisted host gets no decision.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)

HOOK="$CLAUDE_HARNESS_ROOT/hooks/infra-mutation-guard.sh"
[ -f "$HOOK" ] || { echo "FAIL: setup: infra-mutation-guard.sh missing"; exit 1; }

# make_repo <name> <enforce.json content>: prints the repo path.
make_repo() {
  local d="$WORK/$1"
  mkdir -p "$d"
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$d" init -q
  printf '%s\n' "$2" > "$d/.enforce.json"
  printf '%s' "$d"
}

# run_hook <repo> <command>: sets OUT and STATUS.
run_hook() {
  local payload
  payload=$(jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  STATUS=0
  OUT=$(cd "$1" && printf '%s' "$payload" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    CLAUDE_FIRE_LOG=/dev/null bash "$HOOK" 2>/dev/null) || STATUS=$?
}

decision() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo not-json; }

CMD='curl -X DELETE https://api.dns.acme.net/zones/1'

# expect_config_deny <label> <enforce.json content>
expect_config_deny() {
  local repo d
  repo=$(make_repo "$1" "$2")
  run_hook "$repo" "$CMD"
  [ "$STATUS" -eq 0 ] || { echo "FAIL: $1: hook exited $STATUS"; exit 1; }
  d=$(decision)
  [ "$d" = deny ] || { echo "FAIL: $1: expected deny, got $d: $OUT"; exit 1; }
  printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | grep -qF '.enforce.json' \
    || { echo "FAIL: $1: reason does not name .enforce.json: $OUT"; exit 1; }
}

# Control: a well-formed list denies the call, and the reason is not a config error.
repo=$(make_repo good '{"provider_hosts":["api.dns.acme.net"]}')
run_hook "$repo" "$CMD"
[ "$STATUS" -eq 0 ] && [ "$(decision)" = deny ] || { echo "FAIL: control: expected deny for a listed provider host, got status $STATUS: $OUT"; exit 1; }
if printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | grep -qi 'malformed\|invalid'; then
  echo "FAIL: control: a well-formed provider_hosts reported as malformed: $OUT"; exit 1
fi
run_hook "$repo" 'curl https://api.dns.acme.net/zones'
[ "$STATUS" -eq 0 ] && [ "$(decision)" != deny ] || { echo "FAIL: control: a GET to a listed host must not deny: $OUT"; exit 1; }

# 1. A string where a list belongs.
expect_config_deny "provider_hosts string" '{"provider_hosts":"api.dns.acme.net"}'

# 2. A list holding a number.
expect_config_deny "provider_hosts number" '{"provider_hosts":["api.dns.acme.net", 5]}'

echo "PASS: infra-mutation-guard-provider-hosts"
