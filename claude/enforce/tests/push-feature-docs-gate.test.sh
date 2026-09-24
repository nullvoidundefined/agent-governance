#!/usr/bin/env bash
# Covers: hook:push-feature-docs-gate
# Verifies hooks/push-feature-docs-gate.sh (R-607, spec B-12 to B-15): a git
# push whose outgoing diff adds a route without the product docs is denied
# with the checklist report; a complete diff and a non-push command pass; the
# gate runs the harness's canonical script and never the repository's own
# copy; an exempt repository passes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-feature-docs-gate.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
PUSH='{"tool_name":"Bash","tool_input":{"command":"git push origin feat/x"}}'
STATUS='{"tool_name":"Bash","tool_input":{"command":"git status"}}'

fail=0
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
OUT=""

# check <name> <command...>: records one PASS or FAIL line for an assertion.
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }

# is_deny: true when the last gate output is a PreToolUse deny.
is_deny() { printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }

# reason_has <text>: true when the deny reason contains the text.
reason_has() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qF -- "$1"; }

# make_repo <name> <path>...: a repository on feat/x whose branch commit adds
# each path; prints the repository path.
make_repo() {
  local dir="$SB/$1"; shift
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  git -C "$dir" remote add origin "https://example.invalid/$(basename "$dir").git"
  printf '# app\n' > "$dir/README.md"; git -C "$dir" add -A; git -C "$dir" commit -qm init
  git -C "$dir" switch -q -c feat/x
  local path
  for path in "$@"; do mkdir -p "$dir/$(dirname "$path")"; printf 'x\n' > "$dir/$path"; done
  git -C "$dir" add -A; git -C "$dir" commit -qm feature
  printf '%s' "$dir"
}

# run_gate <repo> <payload> [home]: runs the hook from inside the repository
# with the outgoing base pinned to main; sets OUT.
run_gate() {
  OUT=$(cd "$1" && printf '%s' "$2" | HOME="${3:-$SB/home}" CLAUDE_ENFORCE_BASE=main "$HOOK" 2>/dev/null)
}
mkdir -p "$SB/home"

# B-12: a new FastAPI router without product docs is denied with the report.
R=$(make_repo b12 app/routers/trips.py); run_gate "$R" "$PUSH"
check "B-12 missing docs denies" is_deny
check "B-12 reason names R-607" reason_has "R-607"
check "B-12 reason names the trigger" reason_has "app/routers/trips.py"

# B-13: a complete diff passes; a command that is not a push passes.
R=$(make_repo b13 app/routers/trips.py docs/feature-list/features.md docs/user-stories/trips.md e2e/trips.spec.ts)
run_gate "$R" "$PUSH"
check "B-13 complete diff emits nothing" test -z "$OUT"
R=$(make_repo b13status app/routers/trips.py); run_gate "$R" "$STATUS"
check "B-13 non-push emits nothing" test -z "$OUT"

# B-14: the repository's own copy is never executed, even when it would pass.
R=$(make_repo b14 src/app/trips/page.tsx)
mkdir -p "$R/scripts"
printf '#!/usr/bin/env bash\ntouch "%s/repo-copy-ran"\nexit 0\n' "$SB" > "$R/scripts/require-feature-checklist.sh"
chmod +x "$R/scripts/require-feature-checklist.sh"; git -C "$R" add -A; git -C "$R" commit -qm "repo copy"
run_gate "$R" "$PUSH"
check "B-14 canonical script still denies" is_deny
check "B-14 repository copy never ran" test ! -e "$SB/repo-copy-ran"

# B-15: an exempt repository passes.
R=$(make_repo b15 src/app/trips/page.tsx)
mkdir -p "$SB/exempt-home/.claude/enforce"
printf 'https://example.invalid/b15.git\n' > "$SB/exempt-home/.claude/enforce/exempt-repos.txt"
run_gate "$R" "$PUSH" "$SB/exempt-home"
check "B-15 exempt repository emits nothing" test -z "$OUT"

# B-16 (R-608): a Gemfile gem added without docs/stack.md is denied with the
# stack report; the same push with the doc passes.
R=$(make_repo b16 Gemfile)
printf 'source "https://rubygems.org"\ngem "sidekiq"\n' > "$R/Gemfile"; git -C "$R" add -A; git -C "$R" commit -qm gem
run_gate "$R" "$PUSH"
check "B-16 missing stack doc denies" is_deny
check "B-16 reason names R-608" reason_has "R-608"
check "B-16 reason names docs/stack.md" reason_has "docs/stack.md"
mkdir -p "$R/docs"; printf '# stack\n' > "$R/docs/stack.md"; git -C "$R" add -A; git -C "$R" commit -qm stack
run_gate "$R" "$PUSH"
check "B-16 stack doc present emits nothing" test -z "$OUT"

# B-17 (R-607 and R-608 together): one deny carries both reports.
R=$(make_repo b17 app/routers/trips.py app/analytics/events.py)
printf 'class AnalyticsEvent(StrEnum):\n    TRIP_CREATED = "trip_created"\n' > "$R/app/analytics/events.py"
git -C "$R" add -A; git -C "$R" commit -qm event
run_gate "$R" "$PUSH"
check "B-17 combined deny" is_deny
check "B-17 reason names R-607" reason_has "R-607"
check "B-17 reason names docs/observability.md" reason_has "docs/observability.md"
# PR #124 review: the two reports are separated by a blank line, so the
# R-608 report starts its own line rather than running on from R-607's.
check "B-17 R-608 report starts its own line" bash -c "printf '%s' \"\$0\" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '^R-608 (stack and observability docs)'" "$OUT"

[ "$fail" -eq 0 ] && echo "push-feature-docs-gate.test.sh PASS"
exit "$fail"
