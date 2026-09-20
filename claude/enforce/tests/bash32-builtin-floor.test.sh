#!/usr/bin/env bash
# Covers: hook:scope-widening-gate, hook:commit-message-guard
# bash32-builtin-floor.test.sh: every hook must run under GNU bash 3.2,
# because that is what macOS ships and what this harness runs under on the
# owner's machine (IAN-267).
#
# On 2026-09-20 PR #96 introduced `mapfile` into scope-widening-gate.sh and
# commit-message-guard.sh. `mapfile` is a bash 4 builtin. Under bash 3.2 both
# hooks aborted at that line, emitted nothing, and a PreToolUse hook that
# emits nothing is an ALLOW, so R-212's scope gate and R-214's out-of-scope
# commit gate silently stopped enforcing. That is the fail-open direction the
# hook convention in enforce/README.md forbids.
#
# CI runs ubuntu with bash 5, so the two behavioural fixtures passed there and
# failed only on the platform the work actually happens on. This fixture is
# the class check rather than the instance check: it fails on any bash 4+ only
# construct in any hook, so the next one is caught at the source rather than
# by a developer wondering why a guard went quiet.
#
# Scope: hooks only. Fixtures and skill scripts run under the same shell but
# are not guards, so a failure there is loud rather than silent; if that
# changes, widen ROOTS below.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOKS="$CLAUDE_HARNESS_ROOT/hooks"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }

# Constructs bash 3.2 does not have. Each is matched as a shell word so a
# mention inside a comment or a string does not trip it; the point is to catch
# the construct being USED.
#   mapfile / readarray : bash 4 builtins, the IAN-267 break
#   declare -A / local -A : associative arrays, bash 4
#   ${var^^} ${var,,}   : case modification, bash 4
#   &>>                 : append-both-streams, bash 4
no_bash4_construct() {
  local label="$1" pattern="$2" hits
  hits=$(grep -rnE "$pattern" "$HOOKS" --include='*.sh' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
  if [ -n "$hits" ]; then
    printf '  %s found:\n%s\n' "$label" "$hits"
    return 1
  fi
  return 0
}

check "no mapfile in any hook" \
  no_bash4_construct "mapfile" '(^|[;&|[:space:]])mapfile[[:space:]]'
check "no readarray in any hook" \
  no_bash4_construct "readarray" '(^|[;&|[:space:]])readarray[[:space:]]'
check "no associative arrays in any hook" \
  no_bash4_construct "declare -A" '(declare|local|typeset)[[:space:]]+-[A-Za-z]*A[A-Za-z]*[[:space:]]'
check "no case-modification expansion in any hook" \
  no_bash4_construct 'case modification' '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^|,,)'
check "no &>> redirect in any hook" \
  no_bash4_construct '&>>' '&>>'

# --- The running shell really is the floor we claim to test against. A
# machine with bash 5 as /bin/bash would pass the greps above while telling
# us nothing about 3.2, so record which shell judged this run. ---
BASH_MAJOR="${BASH_VERSINFO[0]}"
echo "INFO: this run used bash $BASH_VERSION"
if [ "$BASH_MAJOR" -ge 4 ]; then
  echo "INFO: bash $BASH_MAJOR cannot execute-test the 3.2 floor; the greps above are the whole check here."
fi

# --- Behavioural anchor. The greps are a proxy; this is the thing that
# actually broke. Both guards must produce output when handed an
# out-of-scope target, on whatever bash is running. Empty output is the
# fail-open signature IAN-267 was filed for. ---
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"; mkdir -p "$REPO/src" "$REPO/.claude"
git -C "$REPO" init -q -b feat/scoped
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/src/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm init
cat > "$REPO/.claude/task-tier.json" <<JSON
{"tier":"standard","reason":"t","branch":"feat/scoped","ticket":"IAN-1","scope":["src/"]}
JSON

OUT=$(cd "$REPO" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/other/b.txt","content":"x"}}' "$REPO" \
  | bash "$HOOKS/scope-widening-gate.sh" 2>&1)
check "the scope gate does not abort with a missing builtin" \
  bash -c '! grep -qE "command not found|unbound variable" <<< "$0"' "$OUT"

[ "$fail" -eq 0 ] && echo "bash32-builtin-floor.test.sh PASS"
exit "$fail"
