#!/usr/bin/env bash
# git-invocation.test.sh: unit cover for hooks/git-invocation.sh, the helper
# every push- and commit-boundary hook shares.
#
# The helper does two things that pull against each other. strip_git_global_options
# removes git's global options so that `git --no-pager push` is recognized as a
# push, and parse_git_target_options recovers, from the same command, which
# repository that push names. Until the 2026-09-18 audit only the first half
# existed, so a gate recognized `git -C /other/repo push` correctly and then ran
# every one of its own queries against the repository the hook process happened
# to sit in: the wrong diff and the wrong exemptions (defect 4). The two halves
# are asserted together here because the bug lived in the gap between them, and
# because the end-to-end proof in push-eslint-gate.test.sh is expensive enough
# that it cannot reasonably enumerate every option shape.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
# shellcheck source=../../hooks/git-invocation.sh
source "$CLAUDE_HARNESS_ROOT/hooks/git-invocation.sh"

fail=0

# Reports one named assertion and records a failure without aborting, so a run
# reports every option shape rather than only the first that broke.
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

# Succeeds when stripping the given command leaves the expected text, which is
# what the recognition regexes in every gate then match against.
strips_to() {
  local command_text="$1" expected="$2" actual
  actual=$(printf '%s' "$command_text" | strip_git_global_options)
  [ "$actual" = "$expected" ] && return 0
  echo "  stripped to '$actual', expected '$expected'"
  return 1
}

# Succeeds when the parsed target options, joined with single spaces, equal the
# expected list. Joining keeps the comparison readable; the array itself is
# what callers splice in front of a subcommand.
targets() {
  local command_text="$1" wanted="$2" expected="$3" actual
  parse_git_target_options "$command_text" "$wanted"
  actual="${GIT_TARGET_ARGS[*]+${GIT_TARGET_ARGS[*]}}"
  [ "$actual" = "$expected" ] && return 0
  echo "  parsed '$actual', expected '$expected'"
  return 1
}

# Succeeds when the working directory recovered from the parsed target matches.
targets_directory() {
  local command_text="$1" wanted="$2" expected="$3" actual
  parse_git_target_options "$command_text" "$wanted"
  actual=$(read_git_target_directory)
  [ "$actual" = "$expected" ] && return 0
  echo "  recovered '$actual', expected '$expected'"
  return 1
}

# Recognition: the stripper still reduces every global-option shape to the bare
# invocation, including the quoted argument it used to cut in half.
check "a bare invocation is left alone" \
  strips_to "git push origin main" "git push origin main"
check "-C with an unquoted path strips" \
  strips_to "git -C /repos/app push origin main" "git push origin main"
check "--no-pager strips" \
  strips_to "git --no-pager push origin main" "git push origin main"
check "--git-dir and --work-tree strip in their =-joined form" \
  strips_to "git --git-dir=/repos/app/.git --work-tree=/repos/app push" "git push"
check "a double-quoted path strips as one argument" \
  strips_to "git -C \"/repos/my app\" push origin main" "git push origin main"
check "a single-quoted path strips as one argument" \
  strips_to "git -C '/repos/my app' push origin main" "git push origin main"

# Targeting: the same command yields the options that name the repository.
check "-C is recovered" \
  targets "git -C /repos/app push origin main" push "-C /repos/app"
check "--git-dir and --work-tree are recovered in their separate-argument form" \
  targets "git --git-dir /repos/app/.git --work-tree /repos/app push" push \
  "--git-dir /repos/app/.git --work-tree /repos/app"
check "--git-dir and --work-tree are recovered in their =-joined form" \
  targets "git --git-dir=/repos/app/.git --work-tree=/repos/app push" push \
  "--git-dir=/repos/app/.git --work-tree=/repos/app"
check "a quoted path is recovered without its quotes" \
  targets "git -C \"/repos/my app\" push origin main" push "-C /repos/my app"
check "an argument-taking option that is not a target is skipped" \
  targets "git -c core.pager=cat -C /repos/app push" push "-C /repos/app"
check "a bare flag before the target is skipped" \
  targets "git --no-pager -C /repos/app push" push "-C /repos/app"
check "an explicit refspec does not hide the target" \
  targets "git -C /repos/app push origin HEAD:refs/heads/main" push "-C /repos/app"
check "the invocation naming the wanted subcommand wins" \
  targets "git -C /repos/other fetch && git -C /repos/app push" push "-C /repos/app"
check "a command with no target parses to nothing" \
  targets "git push origin main" push ""
check "a command whose git invocation is a different subcommand parses to nothing" \
  targets "git -C /repos/app fetch origin" push ""
check "a -C belonging to another program is not mistaken for git's" \
  targets "make -C /build all && git push" push ""

# The working-directory view, which git-workflow-guard reasons in.
check "-C yields a working directory" \
  targets_directory "git -C /repos/app push" push "/repos/app"
check "--work-tree yields a working directory" \
  targets_directory "git --work-tree=/repos/app push" push "/repos/app"
check "--git-dir alone yields no working directory" \
  targets_directory "git --git-dir=/repos/app/.git push" push ""

[ "$fail" -eq 0 ] && echo "git-invocation.test.sh PASS"
exit "$fail"
