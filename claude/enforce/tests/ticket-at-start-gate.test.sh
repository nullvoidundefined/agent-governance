#!/usr/bin/env bash
# Covers: hook:ticket-at-start-gate
# Verifies hooks/ticket-at-start-gate.sh (R-605, IAN-149): with the tracker
# configured, a Write or Edit of a non-ignored file inside a git work tree, and
# a `git commit` (from the cwd or through `git -C <repo>`), are denied unless
# the repository carries an untracked task-start ledger (.claude/task-tier.json)
# for the current branch whose tier is trivial or whose ticket is a ticket key.
# No tracker, a path outside any work tree, a gitignored path, a path under
# <top>/.claude/, a detached HEAD, a non-commit command, and any other tool are
# allowed; an unparseable ledger is denied as unreadable. Every repository and
# every HOME is a sandbox; the real ~/.claude is never read or written.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/ticket-at-start-gate.sh"
TIER="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CLAUDE_ENFORCE_BASE
export CLAUDE_FIRE_LOG=/dev/null

fail=0
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
SB=$(cd "$SB" && pwd -P)
OUT=""
TRACKED_HOME="$SB/home"
UNTRACKED_HOME="$SB/home-without-tracker"
mkdir -p "$TRACKED_HOME/.claude" "$UNTRACKED_HOME/.claude"
printf '{}\n' > "$TRACKED_HOME/.claude/TICKET-TRACKER.json"

# check <name> <command...>: records one PASS or FAIL line for an assertion.
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }

# is_deny: true when the last gate output is a PreToolUse deny.
is_deny() { jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<< "$OUT"; }

# is_silent: true when the last gate output is empty, which is an allow.
is_silent() { [ -z "$OUT" ]; }

# is_not_deny: true when the last gate output carries no deny decision.
is_not_deny() { ! is_deny; }

# reason_has <text>: true when the deny reason contains the text.
reason_has() {
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "$OUT" 2>/dev/null | grep -qF -- "$1"
}

# make_repo <name>: a repository with one commit on main, switched to feat/x,
# ignoring ignored/ and the ledger; prints its path.
make_repo() {
  local dir="$SB/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  printf '# app\n' > "$dir/README.md"
  printf 'ignored/\n.claude/task-tier.json\n' > "$dir/.gitignore"
  git -C "$dir" add -A; git -C "$dir" commit -qm init
  git -C "$dir" switch -q -c feat/x
  printf '%s' "$dir"
}

# write_ledger <repo> <json>: writes a ledger shape directly (for shapes task-tier.sh refuses).
write_ledger() { mkdir -p "$1/.claude"; printf '%s\n' "$2" > "$1/.claude/task-tier.json"; }

# tier_set <repo> <home> <args...>: records the ledger through task-tier.sh.
tier_set() { local repo="$1" home="$2"; shift 2; (cd "$repo" && HOME="$home" bash "$TIER" set "$@" >/dev/null 2>&1); }

# file_gate <tool> <file> <cwd> [home]: runs the hook on a Write/Edit/other payload; sets OUT.
file_gate() {
  OUT=$(cd "$3" && jq -nc --arg t "$1" --arg f "$2" --arg d "$3" \
    '{tool_name:$t,cwd:$d,tool_input:{file_path:$f,content:"x",old_string:"a",new_string:"b"}}' \
    | HOME="${4:-$TRACKED_HOME}" "$HOOK" 2>/dev/null)
}

# bash_gate <command> <cwd> [home]: runs the hook on a Bash payload; sets OUT.
bash_gate() {
  OUT=$(cd "$2" && jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | HOME="${3:-$TRACKED_HOME}" "$HOOK" 2>/dev/null)
}

COMMIT='git commit -m "feat: x"'
STARTED='"startedAt":1758240000,"startedAtIso":"2025-09-19T00:00:00Z","reason":"r"'

check "hook exists and is executable" test -x "$HOOK"

# G-1: no ledger, tracker configured: Write of a new file and Edit of a tracked file are denied.
R=$(make_repo g1)
file_gate Write "$R/src/new.ts" "$R"
check "G-1 Write of a new file with no ledger denies" is_deny
check "G-1 reason names R-605" reason_has "R-605"
check "G-1 reason names /ticket-lifecycle" reason_has "/ticket-lifecycle"
check "G-1 reason names task-tier.sh set" reason_has "task-tier.sh set"
check "G-1 reason names --ticket" reason_has "--ticket"
file_gate Edit "$R/README.md" "$R"
check "G-1 Edit of a tracked file with no ledger denies" is_deny

# G-2: a standard ledger for feat/x with a ticket allows.
R=$(make_repo g2)
tier_set "$R" "$TRACKED_HOME" standard "multi-file change" --ticket IAN-7
file_gate Write "$R/src/new.ts" "$R"
check "G-2 Write with a ticketed standard ledger allows" is_silent
file_gate Edit "$R/README.md" "$R"
check "G-2 Edit with a ticketed standard ledger allows" is_silent

# G-3: a standard ledger for feat/x with no ticket denies.
R=$(make_repo g3)
write_ledger "$R" "{\"tier\":\"standard\",\"branch\":\"feat/x\",$STARTED}"
file_gate Write "$R/src/new.ts" "$R"
check "G-3 standard ledger without a ticket denies" is_deny

# G-4: a trivial ledger for feat/x with no ticket allows.
R=$(make_repo g4)
tier_set "$R" "$TRACKED_HOME" trivial "one-line typo"
file_gate Edit "$R/README.md" "$R"
check "G-4 trivial ledger without a ticket allows" is_silent

# G-5: a ledger for another branch denies and names that branch.
R=$(make_repo g5)
write_ledger "$R" "{\"tier\":\"standard\",\"branch\":\"feat/old\",\"ticket\":\"IAN-7\",$STARTED}"
file_gate Write "$R/src/new.ts" "$R"
check "G-5 ledger for another branch denies" is_deny
check "G-5 reason names the ledger's branch" reason_has "feat/old"

# G-6: a ledger committed to git is not session state: deny.
R=$(make_repo g6)
write_ledger "$R" "{\"tier\":\"standard\",\"branch\":\"feat/x\",\"ticket\":\"IAN-7\",$STARTED}"
git -C "$R" add -f .claude/task-tier.json; git -C "$R" commit -qm "chore: ledger"
file_gate Write "$R/src/new.ts" "$R"
check "G-6 tracked ledger with a ticket denies" is_deny

# G-7: tracker not configured: allow everything with no ledger.
R=$(make_repo g7)
file_gate Write "$R/src/new.ts" "$R" "$UNTRACKED_HOME"
check "G-7 untracked Write allows" is_silent
file_gate Edit "$R/README.md" "$R" "$UNTRACKED_HOME"
check "G-7 untracked Edit allows" is_silent
bash_gate "$COMMIT" "$R" "$UNTRACKED_HOME"
check "G-7 untracked commit allows" is_silent

# G-8: a path outside any git work tree allows, judged by the path even from a repo cwd.
R=$(make_repo g8)
PLAIN="$SB/plain"; mkdir -p "$PLAIN"; printf 'n\n' > "$PLAIN/notes.txt"
file_gate Edit "$PLAIN/notes.txt" "$PLAIN"
check "G-8 Edit outside a work tree allows" is_silent
file_gate Write "$PLAIN/deep/er/new.txt" "$PLAIN"
check "G-8 Write of a new file with missing parents outside a work tree allows" is_silent
file_gate Write "$PLAIN/deep/er/new.txt" "$R"
check "G-8 Write outside a work tree from a ledgerless repo cwd allows" is_silent

# G-9: a gitignored path and any path under <top>/.claude/ allow.
R=$(make_repo g9)
file_gate Write "$R/ignored/out.txt" "$R"
check "G-9 gitignored path allows" is_silent
file_gate Write "$R/.claude/settings.local.json" "$R"
check "G-9 path under .claude/ allows" is_silent
file_gate Write "$R/.claude/task-tier.json" "$R"
check "G-9 the ledger path itself allows" is_silent

# G-10: detached HEAD (no current branch) allows.
R=$(make_repo g10)
git -C "$R" checkout -q --detach
file_gate Write "$R/src/new.ts" "$R"
check "G-10 detached HEAD Write allows" is_silent
bash_gate "$COMMIT" "$R"
check "G-10 detached HEAD commit allows" is_silent

# G-11: git commit from a cwd inside the repo: deny with no ledger, allow with a ticketed one.
R=$(make_repo g11)
mkdir -p "$R/src"
bash_gate "$COMMIT" "$R"
check "G-11 commit with no ledger denies" is_deny
check "G-11 commit reason names R-605" reason_has "R-605"
bash_gate "$COMMIT" "$R/src"
check "G-11 commit from a subdirectory with no ledger denies" is_deny
tier_set "$R" "$TRACKED_HOME" standard "multi-file change" --ticket IAN-7
bash_gate "$COMMIT" "$R"
check "G-11 commit with a ticketed ledger allows" is_silent

# G-12: git -C <repo> commit from a cwd outside the repo judges <repo>.
R=$(make_repo g12)
bash_gate "git -C $R commit -m \"feat: x\"" "$PLAIN"
check "G-12 git -C commit from outside with no ledger denies" is_deny
tier_set "$R" "$TRACKED_HOME" standard "multi-file change" --ticket IAN-7
bash_gate "git -C $R commit -m \"feat: x\"" "$PLAIN"
check "G-12 git -C commit from outside with a ticketed ledger allows" is_silent

# G-13: commands that are not a commit never deny.
R=$(make_repo g13)
for command in "git status" "ls" "echo hi"; do
  bash_gate "$command" "$R"
  check "G-13 '$command' does not deny" is_not_deny
done

# G-14: an unparseable ledger denies and says it is unreadable.
R=$(make_repo g14)
write_ledger "$R" 'not json {'
file_gate Write "$R/src/new.ts" "$R"
check "G-14 unparseable ledger denies" is_deny
check "G-14 reason says the ledger is unreadable" reason_has "unreadable"

# G-15: tools other than Write, Edit, Bash allow.
R=$(make_repo g15)
for tool in Read Grep Glob; do
  file_gate "$tool" "$R/README.md" "$R"
  check "G-15 $tool allows" is_silent
done

# --- IAN-149 review round 1 ---------------------------------------------------
# make_ticketed <name>: a repo on feat/x with a ledger carrying IAN-7; prints its path.
make_ticketed() { local repo; repo=$(make_repo "$1"); tier_set "$repo" "$TRACKED_HOME" standard "multi-file change" --ticket IAN-7; printf '%s' "$repo"; }

# R-1: a cd/pushd before the commit moves the judged repository.
LL=$(make_repo r1-ledgerless); TK=$(make_ticketed r1-ticketed)
bash_gate "cd $LL && git commit -m \"feat: x\"" "$PLAIN"
check "R-1 cd into a ledgerless repo then commit, from a non-repo cwd, denies" is_deny
bash_gate "cd $TK && git commit -m \"feat: x\"" "$LL"
check "R-1 cd into a ticketed repo then commit, from a ledgerless cwd, allows" is_silent
bash_gate "pushd $LL && git commit -m x" "$PLAIN"
check "R-1 pushd into a ledgerless repo then commit, from a non-repo cwd, denies" is_deny

# R-2: wrapper, prefix, and unreadable shapes of a commit all deny from a ledgerless repo.
R=$(make_repo r2)
while IFS= read -r command; do
  bash_gate "$command" "$R"
  check "R-2 '$command' denies" is_deny
done <<'SHAPES'
FOO=1 git commit -m x
env FOO=1 git commit -m x
time git commit -m x
command git commit -m x
nice -n 5 git commit -m x
if true; then git commit -m x; fi
{ git commit -m x; }
(git commit -m x)
\git commit -m x
/usr/bin/git commit -m x
git -c user.name=a commit -m x
git --no-pager commit -m x
sh -c 'git commit -m x'
bash -c "git commit -m x"
eval "git commit -m x"
SHAPES

# R-2b: commands that mention commit without committing never deny.
while IFS= read -r command; do
  bash_gate "$command" "$R"
  check "R-2b '$command' does not deny" is_not_deny
done <<'SHAPES'
git log --grep commit
echo "git commit -m x"
git status && echo commit
grep -r commit .
SHAPES

# R-7: --work-tree/--git-dir name the judged repository.
R=$(make_repo r7)
bash_gate "git --work-tree=$R --git-dir=$R/.git commit -m x" "$PLAIN"
check "R-7 --work-tree/--git-dir commit of a ledgerless repo denies" is_deny
bash_gate "git --git-dir=$R/.git commit -m x" "$PLAIN"
check "R-7 --git-dir commit of a ledgerless repo denies" is_deny

# R-8: every commit in a compound command is judged.
TK2=$(make_ticketed r8-ticketed-b); LL8=$(make_repo r8-ledgerless)
bash_gate "git -C $TK commit -m a && git -C $LL8 commit -m b" "$PLAIN"
check "R-8 ticketed then ledgerless commit denies" is_deny
bash_gate "git -C $TK commit -m a && git -C $TK2 commit -m b" "$PLAIN"
check "R-8 two ticketed commits allow" is_silent

# R-4: the other-branch deny names the worktree recovery.
R=$(make_repo r4)
write_ledger "$R" "{\"tier\":\"standard\",\"branch\":\"feat/old\",\"ticket\":\"IAN-7\",$STARTED}"
file_gate Write "$R/src/new.ts" "$R"
check "R-4 other-branch ledger denies" is_deny
check "R-4 reason names the worktree recovery" reason_has "worktree"

# R-5: a staged (not committed) ledger is tracked: deny and name git rm --cached.
R=$(make_repo r5)
printf 'ignored/\n' > "$R/.gitignore"; git -C "$R" commit -qam "chore: unignore ledger"
tier_set "$R" "$TRACKED_HOME" standard "r" --ticket IAN-7
git -C "$R" add -A
file_gate Edit "$R/README.md" "$R"
check "R-5 staged ledger denies" is_deny
check "R-5 reason names git rm --cached" reason_has "git rm --cached"

# R-6: HOME unset takes the degraded path explicitly: exit 0, no output, no unbound-variable crash.
R=$(make_repo r6)
R6_ERR="$SB/r6.err"
OUT=$(cd "$R" && jq -nc --arg f "$R/src/new.ts" --arg d "$R" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"x"}}' \
  | env -u HOME "$HOOK" 2>"$R6_ERR"); R6_ST=$?
check "R-6 HOME unset exits 0" test "$R6_ST" -eq 0
check "R-6 HOME unset prints nothing" is_silent
check "R-6 HOME unset has no unbound variable error" bash -c '! grep -q "unbound variable" "$0"' "$R6_ERR"

# --- IAN-149 review round 2 ---------------------------------------------------
# S-1: a directory the hook cannot resolve before a commit denies as unreadable.
# The commands below carry literal shell text ($REPO, $(pwd), $HOME, cd -), never expanded here.
while IFS= read -r command; do
  bash_gate "$command" "$PLAIN"
  check "S-1 '$command' denies" is_deny
  check "S-1 '$command' reason says cannot" reason_has "cannot"
done <<'SHAPES'
cd $REPO && git commit -m x
cd - && git commit -m x
cd $(pwd) && git commit -m x
git -C "$HOME/x" commit -m x
git -C $REPO commit -m x
SHAPES
bash_gate 'cd $REPO && git status' "$PLAIN"
check "S-1 'cd \$REPO && git status' with no commit does not deny" is_not_deny

# S-1b: a tilde in a git target resolves against HOME.
TILDE_HOME="$SB/home-tilde"
mkdir -p "$TILDE_HOME/.claude"; printf '{}\n' > "$TILDE_HOME/.claude/TICKET-TRACKER.json"
TILDE_REPO=$(make_repo home-tilde/r)
bash_gate 'git -C ~/r commit -m x' "$PLAIN" "$TILDE_HOME"
check "S-1b git -C ~/r commit of a ledgerless repo denies" is_deny
tier_set "$TILDE_REPO" "$TILDE_HOME" standard "multi-file change" --ticket IAN-7
bash_gate 'git -C ~/r commit -m x' "$PLAIN" "$TILDE_HOME"
check "S-1b git -C ~/r commit of a ticketed repo allows" is_silent

# S-2: read-only shell strings from a ticketed repo cwd do not deny.
TK3=$(make_ticketed s2-ticketed)
bash_gate 'bash -c "git log --grep=commit"' "$TK3"
check "S-2 bash -c git log --grep=commit allows" is_silent
bash_gate "sh -c 'git show HEAD | grep commit'" "$TK3"
check "S-2 sh -c git show piped to grep commit allows" is_silent

# S-3: --git-dir names the judged repository even when --work-tree points elsewhere.
LL3=$(make_repo s3-ledgerless)
bash_gate "git --git-dir=$LL3/.git --work-tree=$PLAIN commit -m x" "$PLAIN"
check "S-3 --git-dir of a ledgerless repo with a non-repo --work-tree denies" is_deny

# S-4: wrapper options and expansion-built command words before commit deny.
LL4=$(make_repo s4-ledgerless)
bash_gate 'sudo -k git commit -m x' "$LL4"
check "S-4 sudo -k git commit denies" is_deny
bash_gate 'x=git; $x commit -m x' "$LL4"
check "S-4 expansion-built command word then commit denies" is_deny

[ "$fail" -eq 0 ] && echo "ticket-at-start-gate.test.sh PASS"
exit "$fail"
