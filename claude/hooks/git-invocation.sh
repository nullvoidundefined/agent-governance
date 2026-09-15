#!/usr/bin/env bash
# git-invocation.sh: normalize a Bash command so `git <global options>
# <subcommand>` matches hooks written against `git <subcommand>` adjacency.
# Source this from any push- or commit-boundary hook; never re-enumerate
# options inline. The 2026-08-21 audit closed `git -C` and `git -c`; the
# 2026-09-16 audit (P2-1) found `--no-pager`, `--git-dir`, `--work-tree`,
# and every other global option reopening the same bypass because the fix
# enumerated two options instead of stripping the class.
#
# Two shapes are stripped in one pass, options that take an argument
# (separate or `=`-joined) and bare flags; the subcommand itself never
# starts with `-`, so the strip always stops in front of it.

strip_git_global_options() {
  sed -E 's/git([[:space:]]+((-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)([[:space:]]+|=)[^[:space:];&|]+|-{1,2}[A-Za-z][A-Za-z0-9-]*(=[^[:space:];&|]*)?))+/git/g'
}
