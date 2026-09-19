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

# --- B-5: shell quoting, escaping, continuations, and comments read as bash --

# a quoted or escaped flag is the real flag once bash unquotes it
expect deny 'git commit "--no-verify" -m x'
expect deny "git commit '--no-verify' -m x"
expect deny "git commit --no-ver'ify' -m x"
expect deny 'git commit --no-verif\y -m x'
expect deny "git commit \$'--no-verify' -m x"
expect deny 'git commit ""--no-verify -m x'
expect deny 'git commit "-n" -m x'
expect deny 'git push "--no-verify"'

# a partly quoted config key inside -c still names core.hooksPath
expect deny "git -c core.hooks'Path'=/dev/null commit -m x"

# a message whose quoting carries an escaped quote does not swallow the real
# flag that follows it
expect deny "git commit -m 'don'\\''t break' --no-verify"
expect deny 'git commit -m "it\"s" --no-verify'

# a backslash-newline continuation joins the lines into one command
expect deny $'git commit \\\n  --no-verify -m x'
expect deny $'HUSKY=0 \\\ngit commit -m x'

# the flag spelled inside the message is the message, not the flag
expect none 'git commit -m "--no-verify"'
expect none "git commit -m '-n'"
expect none 'git commit -m "fix: --no-verify is banned"'

# an escaped quote inside a message with no flag must keep working
expect none "git commit -m 'don'\\''t break'"
expect none 'git commit -m "it\"s fine"'

# a trailing shell comment is not part of the command
expect none 'git commit -m x # TODO: drop --no-verify from CI'
expect none 'git commit -m x # see -n'
expect none 'git push # HUSKY=0 would skip'

# a # inside a quoted word does not start a comment, and the text stays quoted
expect none 'git commit -m "issue #12 and --no-verify"'

# --- end B-5 ---------------------------------------------------------------

# --- B-6: git recognized however the program is spelled or wrapped ----------

# the program name spelled with a backslash, an absolute path, quotes, or any
# letter case (macOS resolves commands case-insensitively) is still git
expect deny '\git commit --no-verify -m x'
expect deny '/usr/bin/git commit --no-verify -m x'
expect deny '"git" commit --no-verify -m x'
expect deny 'Git commit --no-verify -m x'
expect deny 'GIT commit -n -m x'

# a wrapper in front of git, with or without its own options and arguments,
# does not hide the skip flag, the hook-manager variable, or the hooks path
expect deny 'exec git commit --no-verify -m x'
expect deny 'nohup git commit -n -m x'
expect deny 'time git commit -n -m x'
expect deny 'nice git commit --no-verify -m x'
expect deny 'nice -n 10 git push --no-verify'
expect deny 'timeout 60 git push --no-verify'
expect deny 'timeout -s KILL 60 git push --no-verify'
expect deny 'HUSKY=0 exec git commit -m x'
expect deny 'env -i PATH=/usr/bin:/bin HUSKY=0 git commit -m x'
expect deny 'env -u FOO HUSKY=0 git commit -m x'
expect deny 'command env HUSKY=0 git commit -m x'
expect deny 'sudo HUSKY=0 git commit -m x'
expect deny 'sudo -E rm .git/hooks/pre-commit'
expect deny 'sudo -u root git commit --no-verify -m x'

# xargs runs its arguments as the command, so git or rm behind it counts
expect deny 'echo x | xargs git commit --no-verify -m'
expect deny 'xargs -0 git commit --no-verify -m < /dev/null'
expect deny 'ls .git/hooks/* | xargs rm'

# a shell or eval given a command string runs that string as a command
expect deny 'bash -c "git commit --no-verify -m x"'
expect deny "sh -c 'git commit -n -m x'"
expect deny 'zsh -c "HUSKY=0 git push"'
expect deny 'bash -lc "git commit --no-verify -m x"'
expect deny 'eval "git commit --no-verify -m x"'
expect deny 'eval git commit --no-verify -m x'

# compound-command keywords and ! put git in command position
expect deny '{ git commit --no-verify -m x; }'
expect deny 'if true; then git commit -n -m x; fi'
expect deny 'for i in 1; do git commit -n -m x; done'
expect deny 'while false; do :; done; ! git commit --no-verify -m x'
expect deny 'if git commit --no-verify -m x; then :; fi'

# the same wrappers around ordinary commands must keep working
expect none 'nohup git push'
expect none 'time git commit -m x'
expect none 'timeout 60 git push'
expect none 'bash -c "git status"'
expect none 'eval "git log -n 5"'
expect none '{ git commit -m x; }'
expect none 'xargs rm < files.txt'
expect none 'sudo -E npm install'
expect none 'env -i PATH=/usr/bin git status'

# a wrapper's own flag that looks like a skip flag belongs to the wrapper
expect none 'nice -n 10 git push'
expect none 'time -p git commit -m x'

# other programs whose name contains git are not git
expect none 'gitk --all'
expect none 'git-lfs push --no-verify'
expect none 'legit commit --no-verify'

# --- end B-6 ---------------------------------------------------------------

# --- B-7: git am and git pull skips, other exports, non-skipping values -----

# -n is --no-verify on git am, alone or bundled, and because am has no
# --no-verbose every prefix of --no-verify down to --no-v is unique
expect deny 'git am -n patch.mbox'
expect deny 'git am -3n patch.mbox'
expect deny 'git am --no-v patch.mbox'
expect deny 'git am --no-ve patch.mbox'
expect deny 'git am --no-ver patch.mbox'

# git pull runs the pre-merge-commit and commit-msg hooks, so every way of
# skipping them on pull is a skip
expect deny 'git pull --no-verify'
expect deny 'git pull --no-verify origin main'
expect deny 'git pull --rebase --no-verify'
expect deny 'HUSKY=0 git pull'
expect deny 'git -c core.hooksPath=/dev/null pull'

# bash exports a variable through declare -x, typeset -x, export of a name
# assigned before or after, and set -a, not only through export NAME=value
expect deny 'declare -x HUSKY=0; git commit -m x'
expect deny 'typeset -x HUSKY=0; git commit -m x'
expect deny 'export HUSKY; HUSKY=0; git commit -m x'
expect deny 'HUSKY=0; export HUSKY; git commit -m x'
expect deny 'set -a; HUSKY=0; git commit -m x'
expect deny 'declare -x GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null; git commit -m x'

# husky v4 skips hooks only when HUSKY_SKIP_HOOKS is 1 or true
expect deny 'HUSKY_SKIP_HOOKS=1 git commit -m x'
expect deny 'HUSKY_SKIP_HOOKS=true git commit -m x'

# values of HUSKY_SKIP_HOOKS that keep hooks on must keep working
expect none 'HUSKY_SKIP_HOOKS=0 git commit -m x'
expect none 'HUSKY_SKIP_HOOKS=false git commit -m x'

# a core.hooksPath override on a subcommand that runs no hook skips nothing
expect none 'git -c core.hooksPath=/tmp/h status'
expect none 'git -c core.hooksPath=/tmp/h log -n 3'
expect none 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=.githooks git status'

# a shell variable that is never exported does not reach git
expect none 'HUSKY=0; git commit -m x'
expect none 'declare HUSKY=0; git commit -m x'

# am and pull flags that do not skip hooks; pull -n is --no-stat
expect none 'git am -3 patch.mbox'
expect none 'git am --continue'
expect none 'git pull --no-rebase origin main'
expect none 'git pull -n'

# --- end B-7 ---------------------------------------------------------------

# --- B-8: indirect hook-config changes: includes, aliases, config files, a git
# function, and git config writes to the protected keys ---------------------

# a config include or a hook-skipping alias injected for one command, through
# -c or through the GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n
# variables, can point core.hooksPath anywhere or expand to a skip flag
expect deny 'git -c include.path=/tmp/evil.gitconfig commit -m x'
expect deny 'git -c includeIf.gitdir:/tmp/.path=/tmp/evil.gitconfig commit -m x'
expect deny 'git -c alias.ci="commit --no-verify" ci -m x'
expect deny 'git -c alias.ci="commit -n" ci -m x'
expect deny 'git -c alias.p="!git push --no-verify" p'
expect deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0="commit -n" git ci -m x'
expect deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=include.path GIT_CONFIG_VALUE_0=/tmp/e git commit -m x'

# pointing git at another global or system config file, directly or by moving
# HOME or XDG_CONFIG_HOME, in front of a hook-running command
expect deny 'GIT_CONFIG_GLOBAL=/tmp/evil git commit -m x'
expect deny 'GIT_CONFIG_SYSTEM=/tmp/evil git push'
expect deny 'HOME=/tmp/evilhome git commit -m x'
expect deny 'XDG_CONFIG_HOME=/tmp/x git commit -m x'
expect deny 'export GIT_CONFIG_GLOBAL=/tmp/evil; git commit -m x'

# redefining git as a shell function or an alias replaces every later git call
expect deny 'git() { command git -c core.hooksPath=/dev/null "$@"; }; git commit -m x'
expect deny 'function git { command git "$@" --no-verify; }; git commit -m x'
expect deny 'shopt -s expand_aliases; alias git="git -c core.hooksPath=/dev/null"; git commit -m x'

# git config writes to core.hooksPath, include paths, or hook-skipping aliases,
# however the key is quoted, the global options are placed, or the write is
# spelled (the set and unset subcommands, --unset-all, --add, --global)
expect deny 'git -C . config core.hooksPath /dev/null'
expect deny 'git --git-dir=.git config core.hooksPath /dev/null'
expect deny "git config 'core.hooksPath' /dev/null"
expect deny 'git config "core.hooksPath" /dev/null'
expect deny 'git config set core.hooksPath /dev/null'
expect deny 'git config unset core.hooksPath'
expect deny 'git config --unset-all core.hooksPath'
expect deny 'git config --global include.path /tmp/evil.gitconfig'
expect deny 'git config --add include.path /tmp/evil.gitconfig'
expect deny 'git config alias.ci "commit --no-verify"'
expect deny "git config --global alias.p '!git push --no-verify'"

# reads of the protected keys, including with redirects, must keep working
expect none 'git config core.hooksPath 2>/dev/null'
expect none 'git config --get core.hooksPath 2>/dev/null || echo unset'
expect none 'git config core.hooksPath > /tmp/hp.txt'
expect none 'git config --get-regexp alias'
expect none 'git config --list'
expect none 'git config get core.hooksPath'
expect none 'git config --get include.path'

# ordinary config writes and aliases that skip nothing must keep working, as
# must an include on a command that runs no hook
expect none 'git config --global user.name x'
expect none 'git config user.email x'
expect none 'git config alias.st status'
expect none 'git config alias.lg "log --oneline"'
expect none 'git -c alias.lg="log --oneline" lg'
expect none 'git -c include.path=/tmp/e.gitconfig status'

# another config file for a command that runs no hook skips nothing
expect none 'HOME=/tmp/h git status'
expect none 'GIT_CONFIG_GLOBAL=/dev/null git log -n 3'

# text that only mentions these forms is not an invocation
expect none 'echo "git() {"'
expect none 'grep -rn "alias.ci" .'
expect none 'git commit -m "alias git to nothing"'

# --- end B-8 ---------------------------------------------------------------

# --- B-9: .git/hooks tampering through other path spellings and tools, and
# hooks-directory housekeeping that removes or disables no real hook --------

# a doubled slash, a ./ segment, a glob, a quoted segment, or a path that git
# itself resolves still names the hooks directory
expect deny 'rm .git//hooks/pre-commit'
expect deny 'rm ./.git/hooks/pre-commit'
expect deny 'rm .git/./hooks/pre-commit'
expect deny 'rm -rf .git/ho*'
expect deny 'rm .git/hooks*/pre-*'
expect deny "rm .git/'hooks'/pre-commit"
expect deny 'rm "$(git rev-parse --git-path hooks)/pre-commit"'
expect deny 'rm $(git rev-parse --git-dir)/hooks/pre-commit'
expect deny 'rm "$(git rev-parse --git-common-dir)/hooks/pre-push"'

# changing into .git or .git/hooks first, in the same command, and then
# removing or disabling a hook by its relative name
expect deny 'cd .git/hooks && rm pre-commit'
expect deny 'cd .git && rm -rf hooks'
expect deny 'cd .git/hooks; chmod -x pre-push'

# other tools that empty, overwrite, rewrite in place, delete, or strip the
# execute bit from a hook file, including recursive chmod on .git or the hooks
expect deny 'dd if=/dev/null of=.git/hooks/pre-commit'
expect deny 'rsync /tmp/empty .git/hooks/pre-commit'
expect deny ': >| .git/hooks/pre-commit'
expect deny 'perl -pi -e "s/exit 1/exit 0/" .git/hooks/pre-commit'
expect deny 'sed -Ei "s/exit 1/exit 0/" .git/hooks/pre-commit'
expect deny 'sed --in-place "s/exit 1/exit 0/" .git/hooks/pre-commit'
expect deny 'find .git -name pre-commit -delete'
expect deny 'find . -path "*/.git/hooks/*" -delete'
expect deny 'chmod -R a-x .git'
expect deny 'chmod -R 644 .git/hooks'

# adding the execute bit re-enables a hook rather than disabling it
expect none 'chmod +x .git/hooks/pre-commit'
expect none 'chmod 755 .git/hooks/pre-push'
expect none 'chmod u+x .git/hooks/pre-commit'

# git never runs a .sample file, so removing one disables nothing
expect none 'rm .git/hooks/pre-commit.sample'
expect none 'rm .git/hooks/*.sample'
expect none 'find .git/hooks -name "*.sample" -delete'

# copying a hook to a backup beside it leaves the hook in place, and moving a
# hook aside immediately before the harness installer reinstalls it is the
# installer's own upgrade path
expect none 'cp .git/hooks/pre-commit .git/hooks/pre-commit.bak'
expect none 'mv .git/hooks/pre-push .git/hooks/pre-push.legacy.bak && bash claude/hooks/install-git-hooks.sh'

# installing a hook from a tracked template and making it executable
expect none 'cp claude/hooks/pre-push.sample .git/hooks/pre-push && chmod +x .git/hooks/pre-push'

# find with an -exec that only reads a hook changes nothing
expect none 'find .git/hooks -type f -exec head -1 {} \;'
expect none 'find .git/hooks -type f -exec ls -l {} +'

# entering .git to run a read, and paths that only resemble .git/hooks, must
# keep working
expect none 'cd .git && git status'
expect none 'rm -rf .github/hooks'
expect none 'rm .githooks/pre-commit.bak'
expect none 'chmod -R a-x build'

# --- end B-9 ---------------------------------------------------------------

# --- B-10: the guard fails closed when its command parser cannot give a
# complete answer, and a bare redirect into .git/hooks is a write ------------

# bash runs the earlier lines before it reaches a syntax error on a later line,
# so an unclosed quote or backtick further down does not excuse the lines above
expect deny $'git commit --no-verify -m x\necho "'
expect deny $'git commit -n -m x\nls `'
expect deny $'HUSKY=0 git commit -m x\nfoo="'

# the runnable part of a command with a later syntax error has nothing to deny
expect none $'git status\necho "'

# a redirect with no program in front of it still creates or truncates the file
expect deny '> .git/hooks/pre-commit'
expect deny '>.git/hooks/pre-push'
expect deny 'exec > .git/hooks/pre-commit'
expect deny '>> .git/hooks/pre-commit'

# a bare redirect to any other path must keep working
expect none '> /tmp/out.txt'
expect none 'exec > /tmp/log.txt'

# runs the guard at the given path with the given directory placed ahead of the
# existing PATH, so jq and the ordinary tools stay reachable, and prints the
# permission decision the same way decision does
decision_under() {
  B10_OUT=$(jq -n --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | PATH="$2:$PATH" "$1" 2>/dev/null) || true
  if [ -z "$B10_OUT" ]; then echo none; else printf '%s' "$B10_OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

# compares the decision of the guard at the given path, run with the given
# directory ahead of PATH, against the expected decision, counting a mismatch
# in FAILURES exactly as expect does
expect_under() {
  B10_GOT=$(decision_under "$2" "$3" "$4")
  if [ "$B10_GOT" != "$1" ]; then
    echo "FAIL: expected $1, got $B10_GOT for: $4 (guard $2, PATH prefix $3)"
    FAILURES=$((FAILURES + 1))
  fi
}

B10_SHIM_DIR=$(mktemp -d)
B10_COPY_DIR=$(mktemp -d)
B10_EMPTY_DIR=$(mktemp -d)
trap 'rm -rf "$B10_SHIM_DIR" "$B10_COPY_DIR" "$B10_EMPTY_DIR"' EXIT

# a python3 that exists but fails, as the macOS stub does when the developer
# tools are not installed
printf '%s\n' '#!/bin/sh' \
  'echo "xcode-select: note: No developer tools were found" >&2' \
  'exit 1' > "$B10_SHIM_DIR/python3"
chmod +x "$B10_SHIM_DIR/python3"

# the guard copied alone, so its sibling shell-command-segments.py is missing
cp "$HOOK" "$B10_COPY_DIR/destructive-command-guard.sh"
chmod +x "$B10_COPY_DIR/destructive-command-guard.sh"

# with a failing python3, a command that could reach git or its hooks is denied
expect_under deny "$HOOK" "$B10_SHIM_DIR" 'git commit --no-verify -m x'
expect_under deny "$HOOK" "$B10_SHIM_DIR" 'git status'
expect_under deny "$HOOK" "$B10_SHIM_DIR" 'rm .git/hooks/pre-commit'

# with a failing python3, a command that cannot reach git or its hooks is not;
# git and hooks match as whole words or as .git/, never as substrings
expect_under none "$HOOK" "$B10_SHIM_DIR" 'ls -la'
expect_under none "$HOOK" "$B10_SHIM_DIR" 'legit --help'
expect_under none "$HOOK" "$B10_SHIM_DIR" 'echo digit'

# with the parser file missing, the same commands get the same decisions
B10_COPY_HOOK="$B10_COPY_DIR/destructive-command-guard.sh"
expect_under deny "$B10_COPY_HOOK" "$B10_EMPTY_DIR" 'git commit --no-verify -m x'
expect_under deny "$B10_COPY_HOOK" "$B10_EMPTY_DIR" 'git status'
expect_under deny "$B10_COPY_HOOK" "$B10_EMPTY_DIR" 'rm .git/hooks/pre-commit'
expect_under none "$B10_COPY_HOOK" "$B10_EMPTY_DIR" 'ls -la'
expect_under none "$B10_COPY_HOOK" "$B10_EMPTY_DIR" 'legit --help'
expect_under none "$B10_COPY_HOOK" "$B10_EMPTY_DIR" 'echo digit'

# --- end B-10 --------------------------------------------------------------

# --- B-11: git run from substitutions in double quotes and heredoc bodies,
# shell strings behind shell options, text fed to a shell, a substituted
# program name, and a shell alias under any name ------------------------------

# bash runs a command substitution inside double quotes, in either spelling
expect deny 'echo "$(git commit --no-verify -m x)"'
expect deny 'echo "`git commit -n -m x`"'
expect deny 'x="$(HUSKY=0 git push)"'

# bash expands substitutions in the body of a heredoc whose marker is unquoted
expect deny $'cat <<EOF\n$(git commit --no-verify -m x)\nEOF'
expect deny $'git commit -F - <<EOF\nfeat: x `git push --no-verify`\nEOF'

# shell options in front of -c do not hide the command string that -c runs
expect deny 'bash -o pipefail -c "git commit --no-verify -m x"'
expect deny 'bash --norc -c "git commit --no-verify -m x"'
expect deny "bash -euo pipefail -c 'git commit -n -m x'"
expect deny "sh -e -c 'HUSKY=0 git push'"

# text fed to a shell on stdin, by here-string, pipe, or heredoc, runs as a
# command, even when the heredoc marker is quoted
expect deny 'bash <<< "git commit --no-verify -m x"'
expect deny "sh <<< 'HUSKY=0 git push'"
expect deny 'echo "git commit --no-verify -m x" | bash'
expect deny "printf 'git push --no-verify\\n' | sh"
expect deny $'cat <<\'EOF\' | bash\ngit commit -n -m x\nEOF'

# a program name produced by a substitution that locates git is git
expect deny '$(which git) commit -n -m x'
expect deny '$(command -v git) push --no-verify'
expect deny '`which git` commit --no-verify -m x'

# a shell alias under any name whose value skips hooks, whether or not the
# same command goes on to use it
expect deny $'shopt -s expand_aliases\nalias gc=\'git commit --no-verify\'\ngc -m x'
expect deny 'alias gp="HUSKY=0 git push"'

# a quoted heredoc marker keeps the body literal, so nothing in it runs
expect none $'cat <<\'EOF\'\n$(git commit --no-verify -m x)\nEOF'
expect none $'git commit -F - <<\'EOF\'\nfeat: x mentions git push --no-verify\nEOF'

# ordinary commands in the same shapes must keep working
expect none 'echo "$(git rev-parse HEAD)"'
expect none 'bash -o pipefail -c "npm test"'
expect none 'bash <<< "echo hi"'
expect none 'echo "npm test" | bash'
expect none '$(which git) status'
expect none "alias gs='git status'"
expect none "alias ll='ls -la'"

# text piped into a program that is not a shell is data, not a command
expect none 'echo "git commit --no-verify is banned" | grep banned'

# --- end B-11 --------------------------------------------------------------

# --- B-12: the remaining habitual spellings of hook tampering and of direct
# git config file writes, with the housekeeping forms kept allowed -----------

# brace expansion that bash expands into a path naming the hooks directory
expect deny 'rm -rf .git/{hooks,info}'
expect deny 'rm -rf .git/hooks{,.bak}'
expect deny 'rm -rf .{git,x}/hooks'

# find that spares the .sample files but deletes the real hooks beside them
expect deny "find .git/hooks -type f ! -name '*.sample' -delete"
expect deny "find .git/hooks -name '*.sample' -o -name pre-commit -delete"
expect deny "find .git/hooks -not -name '*.sample' -delete"

# renaming a hook to .bak disables it, and a hook-running git command later in
# the same call then runs without it
expect deny 'mv .git/hooks/pre-commit .git/hooks/pre-commit.bak && git commit -m x'
expect deny 'mv .git/hooks/pre-push .git/hooks/pre-push.bak; git push'

# writing a git config file directly can set core.hooksPath, an include, or an
# alias without ever running git config
expect deny "echo 'hooksPath = /dev/null' >> .git/config"
expect deny "printf '[core]\\n\\thooksPath = /dev/null\\n' >> ~/.gitconfig"
expect deny "sed -i '' 's/x/y/' .git/config"
expect deny 'tee -a .git/config < /tmp/snippet'
expect deny 'cp /tmp/evil .git/config'
expect deny 'echo x >> "$HOME/.gitconfig"'
expect deny 'echo x >> ~/.config/git/config'
expect deny 'echo x >> .git/config.worktree'

# short spellings: pushd into the hooks, a .. segment that resolves back into
# them, octal modes with no execute bit, a copied mode, a git global option in
# front of commit -n, the last of two -c values for one alias key, and a hook
# path produced by git rev-parse --git-path
expect deny 'pushd .git/hooks && rm pre-commit && popd'
expect deny 'rm .git/info/../hooks/pre-commit'
expect deny 'chmod 0 .git/hooks/pre-commit'
expect deny 'chmod 00 .git/hooks/pre-push'
expect deny 'chmod --reference=/etc/hosts .git/hooks/pre-commit'
expect deny 'git --attr-source HEAD commit -n -m x'
expect deny 'git -c alias.ci=commit -c alias.ci="commit -n" ci -m x'
expect deny 'rm "$(git rev-parse --git-path hooks/pre-commit)"'

# the installer's own recovery, and a .bak rename followed only by commands
# that run no hook, must keep working
expect none 'mv .git/hooks/pre-push .git/hooks/pre-push.legacy.bak && bash claude/hooks/install-git-hooks.sh'
expect none 'mv .git/hooks/pre-commit .git/hooks/pre-commit.bak && git status'

# a find that deletes only .sample files removes no real hook
expect none "find .git/hooks -name '*.sample' -delete"

# reading a git config file, or copying it out, changes nothing
expect none 'cat .git/config'
expect none 'grep hooksPath ~/.gitconfig'
expect none 'cp .git/config /tmp/config.backup'
expect none "sed -n '1,5p' .git/config"

# brace expansion that names no hook path
expect none 'rm -rf {dist,build}'
expect none 'rm -rf .git/{index.lock,ORIG_HEAD}'

# an executable mode, a pushd elsewhere, and a harmless last -c value for an
# alias key must keep working
expect none 'chmod 755 .git/hooks/pre-commit'
expect none 'pushd src && ls && popd'
expect none 'git -c alias.ci="commit -n" -c alias.ci=commit ci -m x'

# an absolute .git outside the current repository is a throwaway repository,
# not this repository's hooks
expect none 'rm -rf /tmp/fixture-repo/.git'
expect none 'rm -rf "$TMPDIR/repo/.git"'

# --- end B-12 --------------------------------------------------------------

# --- B-13: the guard decides a long command well inside the harness hook
# timeout, because a timed-out hook makes no decision and lets the call through

# the most milliseconds one run of the guard may take on any command below
B13_BOUND_MS=1500

# prints the current wall-clock time in milliseconds
read_clock_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

# builds the payload before the clock starts, times one run of the guard on the
# given command, and counts a wrong decision or an over-bound run in FAILURES,
# naming the case, the elapsed milliseconds, and the bound
expect_within_bound() {
  B13_PAYLOAD=$(jq -n --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}')
  B13_START_MS=$(read_clock_ms)
  B13_OUT=$(printf '%s' "$B13_PAYLOAD" | "$HOOK") || true
  B13_END_MS=$(read_clock_ms)
  B13_ELAPSED_MS=$((B13_END_MS - B13_START_MS))
  if [ -z "$B13_OUT" ]; then
    B13_GOT=none
  else
    B13_GOT=$(printf '%s' "$B13_OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"')
  fi
  echo "B-13 $2: ${B13_ELAPSED_MS}ms (bound ${B13_BOUND_MS}ms), decision $B13_GOT"
  if [ "$B13_GOT" != "$1" ]; then
    echo "FAIL: B-13 $2: expected $1, got $B13_GOT (${B13_ELAPSED_MS}ms)"
    FAILURES=$((FAILURES + 1))
  fi
  if [ "$B13_ELAPSED_MS" -ge "$B13_BOUND_MS" ]; then
    echo "FAIL: B-13 $2: took ${B13_ELAPSED_MS}ms, bound is under ${B13_BOUND_MS}ms"
    FAILURES=$((FAILURES + 1))
  fi
}

# rm with 1500 plain directories and one hook path last is denied, quickly
B13_RM_COMMAND='rm -rf'
B13_INDEX=0
while [ "$B13_INDEX" -lt 1500 ]; do
  B13_RM_COMMAND="$B13_RM_COMMAND dir$B13_INDEX"
  B13_INDEX=$((B13_INDEX + 1))
done
B13_RM_COMMAND="$B13_RM_COMMAND .git/hooks/pre-commit"
expect_within_bound deny 'rm of 1500 directories then a hook path' "$B13_RM_COMMAND"

# git add of 1500 source files runs no hook and is allowed, quickly
B13_ADD_COMMAND='git add'
B13_INDEX=0
while [ "$B13_INDEX" -lt 1500 ]; do
  B13_ADD_COMMAND="$B13_ADD_COMMAND src/file$B13_INDEX.ts"
  B13_INDEX=$((B13_INDEX + 1))
done
expect_within_bound none 'git add of 1500 files' "$B13_ADD_COMMAND"

# echo of 3000 words touches nothing and is allowed, quickly
B13_ECHO_COMMAND='echo'
B13_INDEX=0
while [ "$B13_INDEX" -lt 3000 ]; do
  B13_ECHO_COMMAND="$B13_ECHO_COMMAND w$B13_INDEX"
  B13_INDEX=$((B13_INDEX + 1))
done
expect_within_bound none 'echo of 3000 words' "$B13_ECHO_COMMAND"

# cp of 800 sources into the hooks directory is denied, quickly
B13_CP_COMMAND='cp -r'
B13_INDEX=0
while [ "$B13_INDEX" -lt 800 ]; do
  B13_CP_COMMAND="$B13_CP_COMMAND a$B13_INDEX"
  B13_INDEX=$((B13_INDEX + 1))
done
B13_CP_COMMAND="$B13_CP_COMMAND .git/hooks/"
expect_within_bound deny 'cp of 800 sources into the hooks directory' "$B13_CP_COMMAND"

# --- end B-13 --------------------------------------------------------------

# --- B-14: a substitution ends where bash ends it, and a heredoc body is a
# command only when the heredoc feeds a shell ---------------------------------

# a quoted or escaped ) inside a substitution does not end it, so the command
# after it still runs inside the substitution
expect deny "echo \$(printf ')'; git commit --no-verify -m x)"
expect deny 'x=$(echo "a)b"; git push --no-verify)'
expect deny $'echo "$(printf \'%s\' \')\' ; HUSKY=0 git push)"'
expect deny 'echo $(echo \); git commit -n -m x)'

# a heredoc whose reader is a shell, directly, behind a wrapper, or at the end
# of a pipe, runs its body as commands
expect deny $'bash <<EOF\ngit commit --no-verify -m x\nEOF'
expect deny $'sudo bash <<\'EOF\'\ngit commit -n -m x\nEOF'
expect deny $'env X=1 sh <<EOF\nHUSKY=0 git push\nEOF'
expect deny $'cat <<\'EOF\' | bash\ngit commit --no-verify -m x\nEOF'
expect deny $'cat <<\'EOF\' | tee /tmp/x | sh\ngit push --no-verify\nEOF'

# a heredoc read by a program that is not a shell is data, even when a shell
# name appears among that program's arguments
expect none $'cat bash <<\'EOF\'\ngit commit --no-verify -m x\nEOF'
expect none $'grep sh <<\'EOF\'\nHUSKY=0 git push\nEOF'
expect none $'echo run bash later <<\'EOF\'\ngit commit -n -m x\nEOF'

# a heredoc piped into a program that is not a shell is data
expect none $'cat <<\'EOF\' | grep bash\ngit commit --no-verify -m x\nEOF'

# a substitution holding a quoted ) and nothing to deny must keep working
expect none "echo \$(printf ')')"
expect none 'x=$(echo "a)b")'

# --- end B-14 --------------------------------------------------------------

# --- B-15: export state tracked the way bash tracks it within one command:
# set -a and set +a, set -o and set +o allexport, and export -n ------------------

# set -a, set -o allexport, and a bundled -a turn automatic export on, so a
# plain assignment that follows reaches git
expect deny 'set -a; HUSKY=0; git commit -m x'
expect deny 'set -o allexport; HUSKY=0; git commit -m x'
expect deny 'set -ea; HUSKY=0; git commit -m x'

# the last set wins: allexport turned off and then on again is on
expect deny 'set +a; set -a; HUSKY=0; git commit -m x'
expect deny 'set -a; set +a; set -a; HUSKY=0; git commit -m x'

# export -n removes the attribute, and a later export NAME restores it
expect deny 'export HUSKY=0; export -n HUSKY; export HUSKY; git commit -m x'

# set +a and set +o allexport turn automatic export off, so a plain assignment
# after them stays a shell variable that git never sees
expect none 'set +o allexport; HUSKY=0; git commit -m x'
expect none 'set +a; HUSKY=0; git commit -m x'
expect none 'set -a; set +a; HUSKY=0; git commit -m x'
expect none 'set -o allexport; set +o allexport; HUSKY=0; git commit -m x'

# a bundle of set flags without a leaves allexport off
expect none 'set -euo pipefail; HUSKY=0; git commit -m x'

# export -n unexports a name exported earlier in the same command
expect none 'export HUSKY=0; export -n HUSKY; git commit -m x'

# --- end B-15 --------------------------------------------------------------

if [ "$FAILURES" -gt 0 ]; then
  echo "hook-bypass-guard.test.sh FAIL ($FAILURES)"
  exit 1
fi
echo "hook-bypass-guard.test.sh PASS"
