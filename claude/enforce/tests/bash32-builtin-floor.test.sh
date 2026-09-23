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
# failed only on the platform the work actually happens on.
#
# Two layers, because either alone is insufficient:
#
#   1. The greps below name constructs bash 3.2 lacks. They are cheap and they
#      point at the offending line, but they can only catch a construct
#      somebody thought to list.
#   2. The behavioural anchors drive each guard end to end and assert it
#      emits its DECISION. They must assert the positive: the first version
#      of this fixture only checked that the output lacked "command not
#      found", which an empty output satisfies, so it passed against a guard
#      sabotaged into silence. Asserting absence of an error cannot detect a
#      fail-open; only asserting presence of the decision can.
#
# What layer 2 does and does not cover, measured rather than assumed. Under
# bash 3.2 a parse-time error (`;;&`, an unbalanced construct) kills the hook
# before it writes anything, and the anchors catch that whether or not the
# construct is listed above: sabotaging a scratch copy this way turns the
# anchor red. An expansion error does NOT kill it: `${v^^}` prints "bad
# substitution" to stderr, fails that one command, and execution continues,
# so the hook can carry on with a wrong value and still emit a decision. The
# original IAN-267 break was fatal only because `mapfile` left SCOPE unset
# and the next line read it under `set -u`.
#
# So the residual gap is a bash 4 construct that is not listed above AND
# corrupts a value without aborting. Neither layer catches that, and no
# fixture of this shape can. The behavioural fixtures for each guard are what
# would catch it, on a machine running the floor.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

# Every tree holding guards that run under the same shell. The adapter hooks
# on the port surfaces are guards too, and sit outside the Claude hooks
# directory, so a bash 4 construct there would break the ports the same way.
HOOK_ROOTS=(
  "$CLAUDE_HARNESS_ROOT/hooks"
  "$CLAUDE_HARNESS_ROOT/../codex/hooks"
  "$CLAUDE_HARNESS_ROOT/../cursor/hooks"
)

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }

# no_bash4_construct: fails when $2 matches a non-comment line in any hook
# root that exists. The filter drops only lines whose first non-blank
# character is `#`; a construct named inside a string or a trailing comment
# still matches, which is the safe direction for a floor check (a false
# positive is a visible failure, a false negative is a silent allow in
# production). Rename the mention if one ever trips.
no_bash4_construct() {
  local label="$1" pattern="$2" root hits all=""
  for root in "${HOOK_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    hits=$(grep -rnE "$pattern" "$root" --include='*.sh' 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    [ -n "$hits" ] && all="$all$hits"$'\n'
  done
  if [ -n "${all//[[:space:]]/}" ]; then
    printf '  %s found:\n%s' "$label" "$all"
    return 1
  fi
  return 0
}

# Trailing context is ([[:space:]]|$) throughout: a construct at end of line
# has no trailing character, and requiring one missed `declare -A` written
# last on its line.
check "no mapfile in any hook" \
  no_bash4_construct "mapfile" '(^|[;&|[:space:]])mapfile([[:space:]]|$)'
check "no readarray in any hook" \
  no_bash4_construct "readarray" '(^|[;&|[:space:]])readarray([[:space:]]|$)'
check "no coproc in any hook" \
  no_bash4_construct "coproc" '(^|[;&|[:space:]])coproc([[:space:]]|$)'
check "no associative arrays in any hook" \
  no_bash4_construct "declare -A" '(declare|local|typeset)[[:space:]]+-[A-Za-z]*A[A-Za-z]*([[:space:]]|$)'
check "no namerefs in any hook" \
  no_bash4_construct "declare -n" '(declare|local|typeset)[[:space:]]+-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)'
# Single ^ and , are bash 4 too: ${v^} upper-cases the first character.
check "no case-modification expansion in any hook" \
  no_bash4_construct "case modification" '\$\{[#!]?[A-Za-z0-9_@*]+(\[[^]]*\])?(\^\^?|,,?)'
check "no &>> redirect in any hook" \
  no_bash4_construct '&>>' '&>>'
check "no ;;& or ;& case fallthrough in any hook" \
  no_bash4_construct "case fallthrough" ';;?&([[:space:]]|$)'
check "no globstar in any hook" \
  no_bash4_construct "globstar" 'shopt[[:space:]]+-[su][[:space:]]+globstar'

echo "INFO: this run used bash $BASH_VERSION"
[ "${BASH_VERSINFO[0]}" -ge 4 ] && \
  echo "INFO: bash ${BASH_VERSINFO[0]} cannot execute-test the 3.2 floor; the anchors below still run."

# --- Behavioural anchors. Each drives a guard that IAN-267 broke and asserts
# the guard emits its decision. An unlisted bash 4 construct aborts the hook
# into silence, and silence fails these. ---
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"; mkdir -p "$REPO/src/api" "$REPO/docs" "$REPO/.claude"
git -C "$REPO" init -q -b feat/scoped
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm init
cat > "$REPO/.claude/task-tier.json" <<JSON
{"tier":"standard","reason":"fixture","branch":"feat/scoped","startedAt":0,"startedAtIso":"2026-09-20T00:00:00Z","ticket":"IAN-300","scope":["src/api/**"]}
JSON

decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }

# R-212: an out-of-scope Write must ask.
OUT=$(jq -n --arg p "$REPO/docs/notes.md" --arg d "$REPO" \
  '{tool_name:"Write",cwd:$d,tool_input:{file_path:$p,content:"x"}}' \
  | bash "$CLAUDE_HARNESS_ROOT/hooks/scope-widening-gate.sh" 2>/dev/null)
check "the scope gate emits an ask on an out-of-scope write (empty output is the fail-open signature)" \
  test "$(decision "$OUT")" = "ask"

# R-214: an out-of-scope staged commit must be denied. This is the other half
# of the IAN-267 break; without it the `# Covers:` line above is grep-only.
printf 'drive-by\n' > "$REPO/docs/notes.md"
git -C "$REPO" add docs/notes.md
OUT=$(jq -n --arg c 'git commit -m "feat(api): handle the thing"' --arg d "$REPO" \
  '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
  | bash "$CLAUDE_HARNESS_ROOT/hooks/commit-message-guard.sh" 2>/dev/null)
check "the commit guard emits a deny on an out-of-scope staged commit (empty output is the fail-open signature)" \
  test "$(decision "$OUT")" = "deny"

# Negative controls: the anchors above must be reacting to the scope, not
# firing unconditionally, or they would pass against a guard that denies
# everything just as happily as against a correct one.
OUT=$(jq -n --arg p "$REPO/src/api/handler.ts" --arg d "$REPO" \
  '{tool_name:"Write",cwd:$d,tool_input:{file_path:$p,content:"x"}}' \
  | bash "$CLAUDE_HARNESS_ROOT/hooks/scope-widening-gate.sh" 2>/dev/null)
check "the scope gate does not ask on an in-scope write" \
  test "$(decision "$OUT")" != "ask"

git -C "$REPO" rm -q --cached docs/notes.md
printf 'changed\n' > "$REPO/src/api/handler.ts"
git -C "$REPO" add src/api/handler.ts
OUT=$(jq -n --arg c 'git commit -m "feat(api): handle the thing"' --arg d "$REPO" \
  '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
  | bash "$CLAUDE_HARNESS_ROOT/hooks/commit-message-guard.sh" 2>/dev/null)
check "the commit guard does not deny an in-scope staged commit" \
  test "$(decision "$OUT")" != "deny"

[ "$fail" -eq 0 ] && echo "bash32-builtin-floor.test.sh PASS"
exit "$fail"
