#!/usr/bin/env bash
# Verifies push-eslint-gate.sh denies a git push whose outgoing diff has an ESLint
# violation, and allows one whose diff is clean.
#
# The second half of the file covers repository targeting (2026-09-18 audit,
# defect 4). The gate strips git's global options before matching, which is how
# `git --no-pager push` came to be recognized, but it then ran every one of its
# own queries (the origin URL for the exemption list, the outgoing base, the
# diff, the toplevel) against whatever repository the hook process happened to
# sit in. A push aimed at another checkout with `git -C`, `--git-dir` or
# `--work-tree` was therefore recognized correctly and judged against the wrong
# diff and the wrong exemptions. Every case below puts a CLEAN repository under
# the hook's feet and the violation in the repository the command names, so a
# gate reading the ambient repository allows where it should deny, and one case
# inverts the two so that a gate which simply denies everything cannot pass.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-eslint-gate.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git commit -q --allow-empty -m init

# Violating change in the outgoing diff -> deny.
printf 'export const a = { b: 2, a: 1 };\n' > bad.ts; git add bad.ts; git commit -q -m bad
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# Clean change in the outgoing diff -> allow (no output).
printf 'export const a = { a: 1, b: 2 };\n' > bad.ts; git add bad.ts; git commit -q -m fix
OUT2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT2" ]

# Changed-line scoping (2026-07-10): pre-existing violation on an UNTOUCHED line
# plus a clean added line -> allow; the same file gaining a violating added
# line -> deny.
printf 'const legacy = { b: 2, a: 1 };\nexport { legacy };\n' > debt.ts; git add debt.ts; git commit -q -m debt
printf 'const legacy = { b: 2, a: 1 };\nconst fresh = { a: 1, b: 2 };\nexport { legacy };\n' > debt.ts
git add debt.ts; git commit -q -m clean-addition
OUT3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT3" ]

printf 'const legacy = { b: 2, a: 1 };\nconst fresh = { a: 1, b: 2 };\nconst worse = { d: 4, c: 3 };\nexport { legacy };\n' > debt.ts
git add debt.ts; git commit -q -m violating-addition
OUT4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT4" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# --- Repository targeting: two isolated repositories -------------------------

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

fail=0

# Reports one named assertion and records a failure without aborting, so a run
# reports every targeting case rather than stopping at the first.
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

# Creates an empty repository on main with one commit, so that HEAD~1 exists
# after the first real change and the branch name is predictable.
new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.email t@example.invalid
  git -C "$dir" config user.name test
  git -C "$dir" commit -q --allow-empty -m init
}

# Writes one file into a repository and commits it, so the change lands in the
# HEAD~1..HEAD window the gate inspects.
commit_file() {
  local dir="$1" name="$2" body="$3"
  printf '%s' "$body" > "$dir/$name"
  git -C "$dir" add "$name"
  git -C "$dir" commit -q -m "change $name"
}

# Runs the gate with the given command while sitting in the given repository
# and prints the decision as deny or allow. The base override pins the window
# to the last commit of whichever repository the gate ends up reading, so the
# two repositories are distinguished by their contents and not by their
# histories.
gate_decision() {
  local ambient="$1" command_text="$2" out
  out=$(cd "$ambient" && jq -n --arg c "$command_text" \
    '{tool_name:"Bash",tool_input:{command:$c}}' | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo deny
  else
    echo allow
  fi
}

# The same run with no base override, so that resolve_outgoing_base itself has
# to answer in the target repository rather than in the ambient one.
gate_decision_resolving_base() {
  local ambient="$1" command_text="$2" out
  out=$(cd "$ambient" && jq -n --arg c "$command_text" \
    '{tool_name:"Bash",tool_input:{command:$c}}' | env -u CLAUDE_ENFORCE_BASE "$HOOK")
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo deny
  else
    echo allow
  fi
}

denies() { [ "$(gate_decision "$1" "$2")" = "deny" ]; }
allows() { [ "$(gate_decision "$1" "$2")" = "allow" ]; }
denies_resolving_base() { [ "$(gate_decision_resolving_base "$1" "$2")" = "deny" ]; }

VIOLATION='export const sorted = { b: 2, a: 1 };
'
CLEAN='export const sorted = { a: 1, b: 2 };
'

# Repository A is where the hook process sits: its outgoing diff is clean, so
# any deny it produces can only have come from reading repository B.
AMBIENT_CLEAN="$SANDBOX/ambient-clean"
new_repo "$AMBIENT_CLEAN"
commit_file "$AMBIENT_CLEAN" "ambient.ts" "$CLEAN"

# Repository A' is the inverse control: violating, and never the push target.
AMBIENT_DIRTY="$SANDBOX/ambient-dirty"
new_repo "$AMBIENT_DIRTY"
commit_file "$AMBIENT_DIRTY" "ambient.ts" "$VIOLATION"

# Repository B is the push target in every case below, and carries the
# violation the gate is supposed to find.
TARGET="$SANDBOX/target"
new_repo "$TARGET"
commit_file "$TARGET" "target.ts" "$VIOLATION"

# Repository B' is a clean push target, used to show the gate is reading the
# target rather than denying whatever it is handed.
TARGET_CLEAN="$SANDBOX/target-clean"
new_repo "$TARGET_CLEAN"
commit_file "$TARGET_CLEAN" "target.ts" "$CLEAN"

# A target whose path contains a space, which the option stripper used to cut
# in half: it consumed up to the first space and left the remainder of the path
# sitting where the subcommand should be, so the push stopped being recognized.
QUOTED_TARGET="$SANDBOX/target with spaces"
new_repo "$QUOTED_TARGET"
commit_file "$QUOTED_TARGET" "target.ts" "$VIOLATION"

check "-C names the repository the gate judges" \
  denies "$AMBIENT_CLEAN" "git -C $TARGET push origin main"
check "--git-dir and --work-tree in their =-joined form name it too" \
  denies "$AMBIENT_CLEAN" "git --git-dir=$TARGET/.git --work-tree=$TARGET push origin main"
check "--git-dir and --work-tree in their separate-argument form name it too" \
  denies "$AMBIENT_CLEAN" "git --git-dir $TARGET/.git --work-tree $TARGET push origin main"
check "a quoted target path survives option stripping" \
  denies "$AMBIENT_CLEAN" "git -C \"$QUOTED_TARGET\" push origin main"
check "an explicit refspec does not hide the target" \
  denies "$AMBIENT_CLEAN" "git -C $TARGET push origin HEAD:refs/heads/main"
check "a clean target is allowed even when the ambient repository violates" \
  allows "$AMBIENT_DIRTY" "git -C $TARGET_CLEAN push origin main"
check "the ambient repository is still judged when no target is named" \
  denies "$AMBIENT_DIRTY" "git push origin main"

# The outgoing base must be resolved in the target as well, not only the diff.
# origin/main is planted one commit behind the violation in the target, while
# the ambient repository has no origin ref at all, so a gate resolving the base
# where it stands finds an empty window and allows.
git -C "$TARGET" update-ref refs/remotes/origin/main HEAD~1
check "the outgoing base is resolved in the target repository" \
  denies_resolving_base "$AMBIENT_CLEAN" "git -C $TARGET push origin main"

[ "$fail" -eq 0 ] || exit 1
echo "push-eslint-gate.test.sh PASS"
