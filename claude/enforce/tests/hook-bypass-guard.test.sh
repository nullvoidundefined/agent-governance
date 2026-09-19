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

# --- B-2: hook managers turned off through an environment variable ---------

# every hook-manager variable, set as an assignment prefix on a hook-running
# git subcommand, turns the hooks off
expect deny 'HUSKY=0 git commit -m x'
expect deny 'HUSKY_SKIP_HOOKS=1 git commit -m x'
expect deny 'HUSKY_SKIP_HOOKS=true git push'
expect deny 'SKIP=eslint git commit -m x'
expect deny 'SKIP=eslint,prettier git push'
expect deny 'LEFTHOOK=0 git push'
expect deny 'LEFTHOOK=false git commit -m x'
expect deny 'LEFTHOOK_EXCLUDE=lint git push'

# every subcommand that runs hooks is covered, not only commit
expect deny 'HUSKY=0 git push'
expect deny 'HUSKY=0 git merge feat/x'
expect deny 'HUSKY=0 git rebase main'
expect deny 'HUSKY=0 git am patch.mbox'

# the variable set through env
expect deny 'env HUSKY=0 git commit -m x'
expect deny 'env SKIP=eslint git push'
expect deny 'env LEFTHOOK=0 git merge feat/x'

# the variable exported earlier in the same command
expect deny 'export HUSKY=0; git commit -m x'
expect deny 'export LEFTHOOK=0 && git push'
expect deny 'export HUSKY_SKIP_HOOKS=1; git rebase main'
expect deny $'export SKIP=eslint\ngit commit -m x'

# several prefixes, in either order, and global options before the subcommand
expect deny 'CI=1 HUSKY=0 git commit -m x'
expect deny 'HUSKY=0 CI=1 git commit -m x'
expect deny 'HUSKY=0 git -C /tmp/r commit -m x'

# a prefixed invocation after a separator still trips it
expect deny 'git add . && HUSKY=0 git commit -m x'

# values that re-enable hooks, commands that are not hook-running git
# subcommands, and quoted or echoed text must keep working
expect none 'HUSKY=1 git commit -m x'
expect none 'LEFTHOOK=1 git push'
expect none 'SKIP=1 npm test'
expect none 'HUSKY=0 npm install'
expect none 'export HUSKY=0'
expect none 'HUSKY=0 git status'
expect none 'export HUSKY=0; git status'
expect none 'git commit -m "HUSKY=0 is banned"'
expect none 'echo HUSKY=0 git commit'

# --- end B-2 ---------------------------------------------------------------

# --- B-3: core.hooksPath overridden for one invocation, without git config --

# the -c global option, in any key case, quoted, empty-valued, and on any
# subcommand, not only commit
expect deny 'git -c core.hooksPath=/dev/null commit -m x'
expect deny 'git -c core.hookspath=/tmp/h push'
expect deny 'git -c CORE.HOOKSPATH=/dev/null commit -m x'
expect deny 'git -c "core.hooksPath=/dev/null" commit -m x'
expect deny 'git -c core.hooksPath= commit -m x'
expect deny 'git -c core.hooksPath=/dev/null rebase main'
expect deny 'git -C /tmp/r -c core.hooksPath=/dev/null commit -m x'

# the --config-env global option, attached and separate
expect deny 'git --config-env=core.hooksPath=EVIL_HOOKS commit -m x'
expect deny 'git --config-env core.hooksPath=EVIL_HOOKS push'

# the GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n variables, as
# prefixes, through env, and exported earlier in the same command
expect deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'
expect deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hookspath GIT_CONFIG_VALUE_0=/dev/null git push'
expect deny 'env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'
expect deny 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null; git commit -m x'
expect deny $'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null\ngit commit -m x'

# the GIT_CONFIG_PARAMETERS variable
expect deny "GIT_CONFIG_PARAMETERS=\"'core.hooksPath'='/dev/null'\" git commit -m x"

# a real override after an unrelated command on a later line or after &&
expect deny $'git status\ngit -c core.hooksPath=/dev/null commit -m x'
expect deny 'git add . && git -c core.hooksPath=/dev/null commit -m x'
expect deny 'git add . && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'

# other config keys, hooksPath reads, quoted or echoed text, searches, and an
# export with no git command in the call must keep working
expect none 'git -c user.name=x commit -m x'
expect none 'git -c core.editor=vim commit'
expect none 'git config core.hooksPath'
expect none 'git config --get core.hooksPath'
expect none 'git commit -m "set core.hooksPath=/dev/null later"'
expect none 'git commit -m "git -c core.hooksPath=x push"'
expect none 'grep -rn core.hooksPath .'
expect none 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x git commit -m x'
expect none 'echo GIT_CONFIG_KEY_0=core.hooksPath'
expect none 'export GIT_CONFIG_KEY_0=core.hooksPath'

# --- end B-3 ---------------------------------------------------------------

# --- B-4: a file under .git/hooks deleted, moved, disabled, or overwritten --

# deleting or moving a hook file, or the whole hooks directory
expect deny 'rm .git/hooks/pre-commit'
expect deny 'rm -f .git/hooks/pre-push'
expect deny 'rm -rf .git/hooks'
expect deny 'unlink .git/hooks/pre-commit'
expect deny 'mv .git/hooks/pre-commit /tmp/pc'
expect deny 'mv .git/hooks .git/hooks.bak'
expect deny 'find .git/hooks -type f -delete'
expect deny 'find .git/hooks -name pre-commit -exec rm {} +'

# stripping the execute bit leaves the file in place but git skips it
expect deny 'chmod -x .git/hooks/pre-commit'
expect deny 'chmod 644 .git/hooks/pre-push'

# truncating, overwriting, or appending to a hook file, by redirect or by tool
expect deny 'truncate -s 0 .git/hooks/pre-commit'
expect deny ': > .git/hooks/pre-commit'
expect deny "echo 'exit 0' > .git/hooks/pre-commit"
expect deny "printf 'exit 0\\n' >> .git/hooks/pre-push"
expect deny 'cp /dev/null .git/hooks/pre-commit'
expect deny 'ln -sf /dev/null .git/hooks/pre-commit'
expect deny 'tee .git/hooks/pre-commit < /dev/null'
expect deny "sed -i '' 's/exit 1/exit 0/' .git/hooks/pre-commit"

# an absolute path, a leading sudo, a separator, and a later line do not hide it
expect deny 'rm /tmp/repo/.git/hooks/pre-commit'
expect deny 'sudo rm .git/hooks/pre-commit'
expect deny 'git status && rm .git/hooks/pre-commit'
expect deny $'git status\nrm .git/hooks/pre-commit'

# reading a hook, copying one out, and running the harness installer must keep
# working, as must quoted or echoed text and deletions of unrelated paths that
# merely resemble the hooks path
expect none 'ls .git/hooks'
expect none 'ls -la .git/hooks/'
expect none 'cat .git/hooks/pre-commit'
expect none 'head -5 .git/hooks/pre-push'
expect none 'test -x .git/hooks/pre-commit'
expect none 'grep -rn exit .git/hooks'
expect none 'diff .git/hooks/pre-commit /tmp/other'
expect none 'cp .git/hooks/pre-commit /tmp/backup'
expect none 'cat .git/hooks/pre-commit > /tmp/copy'
expect none 'bash claude/hooks/install-git-hooks.sh'
expect none 'git commit -m "remove .git/hooks/pre-commit"'
expect none 'echo "rm .git/hooks/pre-commit"'
expect none 'rm -rf node_modules'
expect none 'rm .github/workflows/old.yml'
expect none 'rm docs/git/hooks.md'

# --- end B-4 ---------------------------------------------------------------

if [ "$FAILURES" -gt 0 ]; then
  echo "hook-bypass-guard.test.sh FAIL ($FAILURES)"
  exit 1
fi
echo "hook-bypass-guard.test.sh PASS"
