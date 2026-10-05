#!/usr/bin/env bash
# Verifies that infra-mutation-guard.sh never echoes a secret in a decision
# reason (spec invariant, C10): a token passed as an option value, an
# http -a user:token pair, or a -p<password> glued to mysql is replaced by
# "***" in the reason. The token is built at run time, never written as a
# literal. Each command must reach a decision (ask or deny); the reason must
# contain *** and must not contain the token value.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/infra-mutation-guard.sh"
[ -f "$HOOK" ] || { echo "FAIL: setup: hook missing"; exit 1; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
REPO="$WORK/repo"; mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q

tok="tok$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)"
fail=0

check() {
  local cmd="$1" payload out d reason
  payload=$(jq -n --arg c "$cmd" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  out=$(cd "$REPO" && printf '%s' "$payload" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    CLAUDE_FIRE_LOG=/dev/null bash "$HOOK" 2>/dev/null)
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo "not-json")
  case "$d" in
    ask|deny) ;;
    *) echo "FAIL: no ask/deny decision (got $d) for: ${cmd//$tok/<token>}"; fail=1; return ;;
  esac
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
  case "$reason" in
    *"$tok"*) echo "FAIL: reason leaks the token for: ${cmd//$tok/<token>}"; fail=1; return ;;
  esac
  case "$reason" in
    *'***'*) ;;
    *) echo "FAIL: reason has no *** redaction for: ${cmd//$tok/<token>}: $reason"; fail=1 ;;
  esac
}

check "curl --oauth2-bearer $tok -X DELETE https://api.cloudflare.com/z"
check "vercel --token $tok rm acme"
check "http -a user:$tok DELETE https://api.cloudflare.com/z"
check "mysql -h db.prod.acme.com -p$tok -e \"DROP TABLE t\""

[ "$fail" -eq 0 ] && echo "PASS: infra-mutation-guard-redaction"
exit "$fail"
