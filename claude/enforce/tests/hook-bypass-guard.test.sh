#!/usr/bin/env bash
# Covers: hook:destructive-command-guard
# Verifies destructive-command-guard.sh denies every spelling of a git
# invocation that skips git hooks, and stays silent on the lookalike commands
# that must keep working. Each slice of the hook-bypass work owns one commented
# section below; later slices append their own sections.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/destructive-command-guard.sh"

FAILURES=0

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}
expect() {
  GOT=$(decision "$2")
  if [ "$GOT" != "$1" ]; then
    echo "FAIL: expected $1, got $GOT for: $2"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- B-1: --no-verify on any git subcommand, -n on git commit -------------

# --no-verify skips hooks on every subcommand that runs them
expect deny 'git commit --no-verify -m x'
expect deny 'git commit -m x --no-verify'
expect deny 'git push --no-verify'
expect deny 'git push --no-verify origin feat/x'
expect deny 'git merge --no-verify feat/x'
expect deny 'git rebase --no-verify main'
expect deny 'git am --no-verify patch.mbox'

# git accepts any unique prefix of a long option; on commit, --no-veri and
# --no-verif are unique (--no-ve is not, commit also has --no-verbose)
expect deny 'git commit --no-veri -m x'
expect deny 'git commit --no-verif -m x'

# -n is --no-verify on commit, alone or bundled ahead of an attached argument
expect deny 'git commit -n -m x'
expect deny 'git commit -m x -n'
expect deny 'git commit -an -m x'
expect deny 'git commit -na -m x'
expect deny 'git commit -anm "msg"'

# global options in front of the subcommand do not hide it
expect deny 'git -C /tmp/repo commit --no-verify -m x'
expect deny 'git -c user.name=x commit -n -m x'
expect deny 'git --no-pager commit --no-verify -m x'

# a real invocation after a separator or on a later line still trips it
expect deny 'git add . && git commit --no-verify -m x'
expect deny 'git add .; git commit -n -m x'
expect deny $'git add .\ngit commit --no-verify -m x'

# n inside an attached argument is not the -n flag
expect none 'git commit -mn'
expect none 'git commit -uno -m x'
expect none 'git commit -m "fix -n handling"'

# lookalikes that must keep working: -n means something else on these
# subcommands, and quoted or echoed text is not an invocation
expect none 'git log -n 5'
expect none 'git push -n'
expect none 'git merge -n feat/x'
expect none 'git commit -m "--no-verify is banned"'
expect none 'git status'
expect none 'echo git commit --no-verify'
expect none 'git commit -m x'

# --- end B-1 ---------------------------------------------------------------

if [ "$FAILURES" -gt 0 ]; then
  echo "hook-bypass-guard.test.sh FAIL ($FAILURES)"
  exit 1
fi
echo "hook-bypass-guard.test.sh PASS"
