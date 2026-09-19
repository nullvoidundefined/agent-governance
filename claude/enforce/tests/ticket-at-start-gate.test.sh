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

# --- IAN-149 review round 3 ---------------------------------------------------
# U-1: cd to the toplevel of the cwd's own repo is resolvable: judged by the ledger, not as unreadable.
U1_TK=$(make_ticketed u1-ticketed); mkdir -p "$U1_TK/src"
U1_LL=$(make_repo u1-ledgerless); mkdir -p "$U1_LL/src"
U1_COMMAND='cd "$(git rev-parse --show-toplevel)" && git commit -m x'
bash_gate "$U1_COMMAND" "$U1_TK/src"
check "U-1 cd to the toplevel of a ticketed repo then commit allows" is_silent
bash_gate "$U1_COMMAND" "$U1_LL/src"
check "U-1 cd to the toplevel of a ledgerless repo then commit denies" is_deny
check "U-1 ledgerless deny carries the ticket reason (R-605)" reason_has "R-605"
check "U-1 ledgerless deny is not the unreadable reason" bash -c '! jq -r ".hookSpecificOutput.permissionDecisionReason // \"\"" <<< "$0" | grep -qF cannot' "$OUT"

# U-2: shell strings are read for a real commit subcommand, not the word commit.
U2_TK=$(make_ticketed u2-ticketed); U2_LL=$(make_repo u2-ledgerless)
while IFS= read -r command; do
  bash_gate "$command" "$U2_TK"
  check "U-2 '$command' from a ticketed repo allows" is_silent
done <<'SHAPES'
bash -c "git log --grep commit"
bash -c "git log --grep 'a commit here'"
sh -c 'git -C . log --oneline commit'
SHAPES
while IFS= read -r command; do
  bash_gate "$command" "$U2_LL"
  check "U-2 '$command' from a ledgerless repo denies" is_deny
done <<'SHAPES'
bash -c "git -C . commit -m x"
sh -c 'git -c a=b commit -m x'
SHAPES

# U-3: an expansion-built command word is unreadable only when commit is a real argument.
bash_gate '$EDITOR notes.md # commit later' "$U2_TK"
check "U-3 '\$EDITOR notes.md # commit later' from a ticketed repo allows" is_silent
bash_gate '$GIT -C . commit -m x' "$U2_LL"
check "U-3 '\$GIT -C . commit -m x' from a ledgerless repo denies" is_deny

# --- IAN-149 Copilot round (PR #78) ----------------------------------------------
# V-1: a commit on the second line of a shell string is still a commit.
V1_LL=$(make_repo v1-ledgerless); V1_TK=$(make_ticketed v1-ticketed)
# The hook receives the ANSI-C quoted text as written: bash -c $'echo ok\ngit commit -m x'
V1_ANSI="bash -c \$'echo ok\\ngit commit -m x'"
bash_gate "$V1_ANSI" "$V1_LL"
check "V-1 bash -c \$'echo ok\\ngit commit -m x' denies" is_deny
bash_gate $'sh -c \'echo ok\ngit commit -m x\'' "$V1_LL"
check "V-1 sh -c single-quoted string with the commit on its second line denies" is_deny
bash_gate $'bash -c \'echo ok\ngit log --oneline\'' "$V1_TK"
check "V-1 bash -c two-line read-only string from a ticketed repo allows" is_silent

# V-2: timeout with its option forms before git commit denies.
V2_LL=$(make_repo v2-ledgerless)
while IFS= read -r command; do
  bash_gate "$command" "$V2_LL"
  check "V-2 '$command' denies" is_deny
done <<'SHAPES'
timeout --signal TERM 10 git commit -m x
timeout --signal=TERM 10 git commit -m x
timeout -s TERM 10 git commit -m x
timeout --kill-after=5 10 git commit -m x
timeout --preserve-status 10 git commit -m x
timeout 10s git commit -m x
SHAPES

# --- IAN-149 Copilot round 2 (PR #78) --------------------------------------------
W_LL=$(make_repo w-ledgerless); W_TK=$(make_ticketed w-ticketed)
git -C "$W_TK" branch other2

# W-1: time with its -p option before git commit denies.
bash_gate 'time -p git commit -m x' "$W_LL"
check "W-1 'time -p git commit -m x' denies" is_deny

# W-2: a subcommand built by expansion is unreadable: deny.
bash_gate 'x=commit; git "$x" -m x' "$W_LL"
check "W-2 'x=commit; git \"\$x\" -m x' denies" is_deny
bash_gate 'git $SUB -m x' "$W_LL"
check "W-2 'git \$SUB -m x' denies" is_deny

# W-3: a commit in a directory that is not a work tree before the command runs denies.
W3_NEW="$SB/w3-newrepo"
bash_gate "mkdir -p $W3_NEW; git -C $W3_NEW init; git -C $W3_NEW commit --allow-empty -m x" "$PLAIN"
check "W-3 init-then-commit in a not-yet-existing directory denies" is_deny
check "W-3 the directory still does not exist (the hook ran nothing)" test ! -e "$W3_NEW"

# W-4: GIT_DIR/GIT_WORK_TREE assignments name the judged repository.
bash_gate "GIT_DIR=$W_LL/.git GIT_WORK_TREE=$W_LL git commit -m x" "$W_TK"
check "W-4 GIT_DIR and GIT_WORK_TREE naming a ledgerless repo deny from a ticketed cwd" is_deny
bash_gate "GIT_DIR=$W_LL/.git git commit -m x" "$W_TK"
check "W-4 GIT_DIR naming a ledgerless repo denies from a ticketed cwd" is_deny

# W-4: a GIT_DIR assignment after a shell keyword, wrapper, or leading redirection
# still names the judged repository (the shared strip removes it before the command).
while IFS= read -r command; do
  bash_gate "$command" "$W_TK"
  check "W-4 '$command' from a ticketed cwd denies" is_deny
done <<SHAPES
if GIT_DIR=$W_LL/.git git commit -m x; then :; fi
{ GIT_DIR=$W_LL/.git git commit -m x; }
! GIT_DIR=$W_LL/.git git commit -m x
env GIT_DIR=$W_LL/.git git commit -m x
time GIT_DIR=$W_LL/.git git commit -m x
< /dev/null GIT_DIR=$W_LL/.git git commit -m x
SHAPES

# W-5: a shell -c payload holding an expansion, in a command that mentions commit, is unreadable.
bash_gate 'SCRIPT='"'"'git commit -m x'"'"'; bash -c "$SCRIPT"' "$W_TK"
check "W-5 bash -c \"\$SCRIPT\" with a commit in SCRIPT denies from a ticketed cwd" is_deny

# W-6: a heredoc fed to a shell that commits denies.
bash_gate $'sh -s <<\'EOF\'\ngit commit -m x\nEOF' "$W_LL"
check "W-6 sh -s heredoc holding a commit denies" is_deny
bash_gate $'bash -s <<\'EOF\'\ngit commit -m x\nEOF' "$W_LL"
check "W-6 bash -s heredoc holding a commit denies" is_deny

# W-7: a branch change before a commit in the same command denies (the ledger names feat/x).
while IFS= read -r command; do
  bash_gate "$command" "$W_TK"
  check "W-7 '$command' from a ticketed repo denies" is_deny
done <<'SHAPES'
git switch -c other && git commit -m x
git checkout other2 && git commit -m x
git -C . switch -c third && git commit -m x
SHAPES

# Round-2 allows, from a ticketed repo cwd.
bash_gate 'time git status && git commit -m x' "$W_TK"
check "W allow: 'time git status && git commit -m x' from a ticketed repo" is_silent
bash_gate 'git switch feat/x' "$W_TK"
check "W allow: 'git switch feat/x' alone" is_silent
bash_gate $'bash -s <<\'EOF\'\necho hi\nEOF\ngit commit -m x' "$W_TK"
check "W allow: bash -s heredoc without a commit, then a plain commit, from a ticketed repo" is_silent

# --- IAN-149 review round 6 -----------------------------------------------------
X_TK=$(make_ticketed x-ticketed)

# X-1: expansions in commands that commit nothing never deny.
while IFS= read -r command; do
  bash_gate "$command" "$X_TK"
  check "X-1 '$command' from a ticketed repo allows" is_silent
done <<'SHAPES'
bash scripts/lint.sh "$FILE" && git add "$FILE"
sh -c "echo $HOME"; git status
bash -c "$SCRIPT" && git status
bash -c "git log -1 $SHA"
bash ~/.claude/skills/task-start/scripts/task-tier.sh set standard "$REASON" --ticket IAN-7 && git status
SHAPES

# X-2: a branch switch before a commit is judged against the switched-to branch.
bash_gate 'git checkout feat/x && git commit -m x' "$X_TK"
check "X-2 checkout of the current branch then commit allows" is_silent
bash_gate 'git checkout -b feat/new && git add -A && git commit -m x' "$X_TK"
check "X-2 checkout -b feat/new then commit denies" is_deny
check "X-2 checkout -b deny names feat/new" reason_has "feat/new"
bash_gate 'git switch -c feat/new2 && git commit -m x' "$X_TK"
check "X-2 switch -c feat/new2 then commit denies" is_deny
check "X-2 switch -c deny names feat/new2" reason_has "feat/new2"
bash_gate 'git checkout $BR && git commit -m x' "$X_TK"
check "X-2 checkout \$BR then commit denies" is_deny
check "X-2 checkout \$BR deny says cannot" reason_has "cannot"
bash_gate 'git checkout -- README.md && git commit -m x' "$X_TK"
check "X-2 checkout -- <path> (no branch change) then commit allows" is_silent

# X-2: a ledger for feat/y while on feat/x; switching to feat/y then committing lands on the ledger's branch.
X_Y=$(make_repo x-ledger-for-y)
git -C "$X_Y" branch feat/y
write_ledger "$X_Y" "{\"tier\":\"standard\",\"branch\":\"feat/y\",\"ticket\":\"IAN-7\",$STARTED}"
bash_gate 'git switch feat/y && git commit -m x' "$X_Y"
check "X-2 switch to the ledger's ticketed branch then commit allows" is_silent

# --- IAN-149 review round 7 -----------------------------------------------------
# Y-1: `-` names the previous branch (@{-1}).
# make_repo leaves the repo on feat/x having come from main, so @{-1} is main.
Y_FROM_MAIN=$(make_ticketed y1-on-feat-x)
bash_gate 'git switch - && git commit -m x' "$Y_FROM_MAIN"
check "Y-1 switch - to main (ledger for feat/x) then commit denies" is_deny
check "Y-1 switch - deny names main" reason_has "main"
bash_gate 'git checkout - && git commit -m x' "$Y_FROM_MAIN"
check "Y-1 checkout - to main then commit denies" is_deny
check "Y-1 checkout - deny names main" reason_has "main"
bash_gate 'git switch main && git pull --ff-only 2>/dev/null; git switch - && git commit -m x' "$Y_FROM_MAIN"
check "Y-1 switch main, then switch - back to feat/x, then commit allows" is_silent

# The repo on main having come from feat/x: @{-1} is feat/x, whose ledger carries the ticket.
Y_FROM_FEAT=$(make_ticketed y1-on-main)
git -C "$Y_FROM_FEAT" switch -q main
bash_gate 'git switch - && git commit -m x' "$Y_FROM_FEAT"
check "Y-1 switch - back to feat/x (ticketed) then commit allows" is_silent

# Y-2: restore forms of checkout change no branch.
Y2=$(make_ticketed y2-ticketed)
printf 'two\n' >> "$Y2/README.md"; git -C "$Y2" commit -qam "docs: second line"
while IFS= read -r command; do
  bash_gate "$command" "$Y2"
  check "Y-2 '$command' from a ticketed repo allows" is_silent
done <<'SHAPES'
git checkout main README.md && git commit -m x
git checkout HEAD~1 README.md && git commit -m x
git checkout . && git commit -m x
git checkout README.md && git commit -m x
SHAPES

# --- IAN-149 Copilot round 3 ------------------------------------------------------
# reason_lacks <text>: true when the last output is a deny whose reason does not contain the text.
reason_lacks() { is_deny && ! reason_has "$1"; }

# Z-1: a cd inside an if condition moves the judged repository.
Z_TK=$(make_ticketed z1-ticketed); Z_LL=$(make_repo z1-ledgerless)
bash_gate "if cd $Z_LL; then git commit -m x; fi" "$Z_TK"
check "Z-1 'if cd <ledgerless>; then git commit' from a ticketed cwd denies" is_deny
check "Z-1 deny carries the ticket reason (R-605)" reason_has "R-605"
check "Z-1 deny is not the unreadable reason" reason_lacks "cannot"
bash_gate "if cd $Z_TK; then git commit -m x; fi" "$Z_LL"
check "Z-1 'if cd <ticketed>; then git commit' from a ledgerless cwd allows" is_silent

# Z-2: a ledger still in HEAD is tracked even after a staged git rm --cached.
Z2=$(make_repo z2-ledger-in-head)
write_ledger "$Z2" "{\"tier\":\"standard\",\"branch\":\"feat/x\",\"ticket\":\"IAN-7\",$STARTED}"
git -C "$Z2" add -f .claude/task-tier.json; git -C "$Z2" commit -qm "chore: ledger"
git -C "$Z2" rm -q --cached .claude/task-tier.json
file_gate Edit "$Z2/README.md" "$Z2"
check "Z-2 ledger removed from the index but still in HEAD denies" is_deny
check "Z-2 deny names git rm --cached or tracked" bash -c 'jq -r ".hookSpecificOutput.permissionDecisionReason // \"\"" <<< "$0" | grep -qE "git rm --cached|tracked"' "$OUT"
git -C "$Z2" commit -qm "chore: untrack ledger"
file_gate Edit "$Z2/README.md" "$Z2"
check "Z-2 ledger out of HEAD and the index, still on disk and ignored, allows" is_silent

# --- IAN-149 review round 9 -----------------------------------------------------
# make_committed_ledger_repo <name>: a repo on feat/x whose .gitignore does not list the
# ledger, with a ticketed feat/x ledger committed and then staged for removal
# (git rm --cached: still in HEAD, still on disk); prints its path.
make_committed_ledger_repo() {
  local repo; repo=$(make_repo "$1")
  printf 'ignored/\n' > "$repo/.gitignore"; git -C "$repo" commit -qam "chore: stop ignoring the ledger"
  write_ledger "$repo" "{\"tier\":\"standard\",\"branch\":\"feat/x\",\"ticket\":\"IAN-7\",$STARTED}"
  git -C "$repo" add .claude/task-tier.json && git -C "$repo" commit -qm "chore: ledger"
  git -C "$repo" rm -q --cached .claude/task-tier.json
  printf '%s' "$repo"
}

AA=$(make_committed_ledger_repo aa-recovery)
# AA-4: in the staged-removal state an Edit of README.md still denies.
file_gate Edit "$AA/README.md" "$AA"
check "AA-4 staged-removal state: Edit of README.md denies" is_deny
# AA-1: the recovery step, an Edit of .gitignore, is allowed.
file_gate Edit "$AA/.gitignore" "$AA"
check "AA-1 staged-removal state: Edit of .gitignore allows" is_silent
# AA-2: committing only the ledger removal and the .gitignore change is allowed.
printf '.claude/task-tier.json\n' >> "$AA/.gitignore"; git -C "$AA" add .gitignore
bash_gate 'git commit -m "chore: untrack the ledger"' "$AA"
check "AA-2 commit staging only the ledger removal and .gitignore allows" is_silent

# AA-3: the same staged removal plus a staged README.md change denies as tracked.
AA3=$(make_committed_ledger_repo aa3-mixed)
printf 'more\n' >> "$AA3/README.md"; git -C "$AA3" add README.md
bash_gate 'git commit -m x' "$AA3"
check "AA-3 commit staging the ledger removal plus README.md denies" is_deny
check "AA-3 deny names tracked" reason_has "tracked"

# --- IAN-149 review round 10 ----------------------------------------------------
# BB state: ledger in HEAD, its removal staged, .gitignore updated and staged,
# README.md modified in the working tree but not staged.
BB=$(make_committed_ledger_repo bb-recovery)
printf '.claude/task-tier.json\n' >> "$BB/.gitignore"; git -C "$BB" add .gitignore
printf 'unstaged\n' >> "$BB/README.md"

# BB-1: a commit that would also carry README.md denies as tracked.
while IFS= read -r command; do
  bash_gate "$command" "$BB"
  check "BB-1 '$command' denies" is_deny
  check "BB-1 '$command' reason names tracked" reason_has "tracked"
done <<'SHAPES'
git commit -am x
git commit -a -m x
git commit --all -m x
git commit README.md -m x
git commit --include README.md -m x
git commit -o README.md -m x
git add README.md && git commit -m x
git add -A && git commit -m x
SHAPES

# BB-2: commits carrying only the ledger removal and .gitignore allow.
while IFS= read -r command; do
  bash_gate "$command" "$BB"
  check "BB-2 '$command' allows" is_silent
done <<'SHAPES'
git commit -m "chore: untrack the ledger"
git commit --amend --no-edit
SHAPES

# BB-2: the same state with .gitignore modified but not staged.
BB_UNSTAGED_IGNORE=$(make_committed_ledger_repo bb-ignore-unstaged)
printf '.claude/task-tier.json\n' >> "$BB_UNSTAGED_IGNORE/.gitignore"
printf 'unstaged\n' >> "$BB_UNSTAGED_IGNORE/README.md"
bash_gate 'git add .gitignore && git commit -m x' "$BB_UNSTAGED_IGNORE"
check "BB-2 'git add .gitignore && git commit -m x' allows" is_silent

# BB-2: from before the removal was staged (ledger in HEAD and the index), the whole recovery in one command.
BB_PRE=$(make_repo bb-pre-removal)
printf 'ignored/\n' > "$BB_PRE/.gitignore"; git -C "$BB_PRE" commit -qam "chore: stop ignoring the ledger"
write_ledger "$BB_PRE" "{\"tier\":\"standard\",\"branch\":\"feat/x\",\"ticket\":\"IAN-7\",$STARTED}"
git -C "$BB_PRE" add .claude/task-tier.json && git -C "$BB_PRE" commit -qm "chore: ledger"
printf '.claude/task-tier.json\n' >> "$BB_PRE/.gitignore"
printf 'unstaged\n' >> "$BB_PRE/README.md"
bash_gate 'git rm --cached .claude/task-tier.json && git add .gitignore && git commit -m x' "$BB_PRE"
check "BB-2 'git rm --cached <ledger> && git add .gitignore && git commit -m x' allows" is_silent

# --- IAN-149 review round 11 ----------------------------------------------------
# CC state: the BB state plus a branch `other` whose README.md differs. The branch is
# built through a scratch index so the repo's own staged set is left untouched.
CC=$(make_committed_ledger_repo cc-recovery)
printf '.claude/task-tier.json\n' >> "$CC/.gitignore"; git -C "$CC" add .gitignore
printf 'unstaged\n' >> "$CC/README.md"
CC_BLOB=$(printf '# other\n' | git -C "$CC" hash-object -w --stdin)
CC_INDEX="$SB/cc-scratch-index"
GIT_INDEX_FILE="$CC_INDEX" git -C "$CC" read-tree HEAD
GIT_INDEX_FILE="$CC_INDEX" git -C "$CC" update-index --cacheinfo "100644,$CC_BLOB,README.md"
CC_TREE=$(GIT_INDEX_FILE="$CC_INDEX" git -C "$CC" write-tree)
git -C "$CC" branch other "$(git -C "$CC" commit-tree "$CC_TREE" -p HEAD -m "docs: other readme")"
printf 'README.md\n' > "$CC/paths.txt"

# CC-1: commands that bring README.md into the commit deny as tracked.
while IFS= read -r command; do
  bash_gate "$command" "$CC"
  check "CC-1 '$command' denies" is_deny
  check "CC-1 '$command' reason names tracked" reason_has "tracked"
done <<'SHAPES'
git merge --squash other && git commit -m x
git checkout other -- README.md && git commit -m x
git cherry-pick -n other && git commit -m x
git commit --pathspec-from-file=paths.txt -m x
SHAPES

# CC-2: read-only commands before a commit of only the recovery still allow.
while IFS= read -r command; do
  bash_gate "$command" "$CC"
  check "CC-2 '$command' allows" is_silent
done <<'SHAPES'
git status && git commit -m x
git diff --cached --stat && git commit -m x
SHAPES

[ "$fail" -eq 0 ] && echo "ticket-at-start-gate.test.sh PASS"
exit "$fail"
