#!/usr/bin/env bash
# Verifies the security CI scan-target lister, enforce/security-ci-targets.sh
# (IAN-381, spec Part 7 addendum, criteria B-18 and B-19). The lister runs
# with its working directory inside the repository to scan and prints the scan
# targets, one repository-relative path per line, exiting 0:
#
#   security-ci-targets.sh --mode pr --base <base-ref>
#     PR mode: every file that HEAD adds, copies, modifies, or renames into,
#     relative to `git merge-base <base-ref> HEAD`, minus deleted files. The
#     diff starts at the merge base, so a file the base branch gained after
#     the PR branch was cut is not a target, and a renamed file is listed under
#     its new name only.
#   security-ci-targets.sh --mode full
#     Full mode: every file tracked at HEAD.
#
# Neither mode reads `.enforce.json` `securitySurfaceExclude`, from the base
# commit or from HEAD. R-109 scopes that list to the security-surface detector
# and gives the Semgrep rule pack no exclude list at all (owner decision
# 2026-09-27), so a path may leave the security review's view but never the
# rule pack's. The fixtures therefore put files under both a base-commit glob
# and a glob the PR adds, and expect every one of them among the targets.
#
# The lister fails closed: when git cannot resolve the base ref, or the mode
# or arguments are invalid, it exits 2 with a message on stderr and prints no
# targets. Every case compares the exact sorted target set and the exact exit
# status, so a lister that over-reports or under-reports fails alike. A path
# holding a space must come through intact, because the CI passes each line
# to Semgrep and CodeQL as one file name.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
LISTER="$CLAUDE_HARNESS_ROOT/enforce/security-ci-targets.sh"

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# git_clean <args...>: runs git with every GIT_* location variable stripped, so
# a fixture run from inside a hook or a worktree never touches the outer repo.
git_clean() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR git "$@"
}

# new_repo <name>: creates a throwaway repository on branch main and prints
# its path.
new_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo"
  git_clean -C "$repo" init -q --initial-branch=main
  git_clean -C "$repo" config user.email t@t
  git_clean -C "$repo" config user.name t
  git_clean -C "$repo" config commit.gpgsign false
  printf '%s' "$repo"
}

# write_file <repo> <relative path> <content>: writes the file, creating its
# directories.
write_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

# commit_all <repo> <message>: commits every change in the repository.
commit_all() {
  git_clean -C "$1" add -A
  git_clean -C "$1" commit -q --allow-empty -m "$2"
}

# run_lister <repo> <args...>: runs the lister from inside the repository with
# the GIT_* variables stripped. Sets LISTER_STDOUT (sorted, byte order),
# LISTER_STDERR, and LISTER_STATUS.
run_lister() {
  local repo="$1"; shift
  local out_file="$WORK/lister.out" err_file="$WORK/lister.err"
  (
    cd "$repo" || exit 96
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR \
      bash "$LISTER" "$@"
  ) > "$out_file" 2> "$err_file"
  LISTER_STATUS=$?
  LISTER_STDOUT=$(LC_ALL=C sort "$out_file")
  LISTER_STDERR=$(cat "$err_file")
}

# expect_targets <label> <expected sorted lines>: the last run must exit 0 and
# print exactly the expected set.
expect_targets() {
  local label="$1" expected="$2"
  [ "$LISTER_STATUS" -eq 0 ] \
    || report_failure "$label: lister must exit 0; got $LISTER_STATUS (stderr: ${LISTER_STDERR:-<none>})"
  [ "$LISTER_STDOUT" = "$expected" ] \
    || report_failure "$label: targets must be exactly [$(printf '%s' "$expected" | tr '\n' '|')]; got [$(printf '%s' "$LISTER_STDOUT" | tr '\n' '|')]"
}

# expect_fail_closed <label>: the last run must exit 2, print nothing on
# stdout, and explain itself on stderr.
expect_fail_closed() {
  local label="$1"
  [ "$LISTER_STATUS" -eq 2 ] || report_failure "$label: lister must exit 2; got $LISTER_STATUS"
  [ -z "$LISTER_STDOUT" ] \
    || report_failure "$label: lister must print no targets; got [$(printf '%s' "$LISTER_STDOUT" | tr '\n' '|')]"
  [ -n "$LISTER_STDERR" ] || report_failure "$label: lister must print a message on stderr"
}

[ -f "$LISTER" ] || report_failure "precondition: $LISTER does not exist"

# --- Shared repository for cases 1 and 2 -------------------------------------
REPO=$(new_repo pr-range)
write_file "$REPO" keep.py $'KEEP = 1\n'
write_file "$REPO" modify.py $'VALUE = 1\n'
write_file "$REPO" delete.py $'GONE = 1\n'
write_file "$REPO" vendor/excluded.py $'VENDORED = 1\n'
write_file "$REPO" .enforce.json $'{ "securitySurfaceExclude": ["vendor/**"] }\n'
commit_all "$REPO" "base"
git_clean -C "$REPO" checkout -q -b feature
write_file "$REPO" added.py $'ADDED = 1\n'
write_file "$REPO" modify.py $'VALUE = 2\n'
write_file "$REPO" vendor/excluded.py $'VENDORED = 2\n'
rm "$REPO/delete.py"
write_file "$REPO" late/excluded-by-head.py $'LATE = 1\n'
write_file "$REPO" .enforce.json $'{ "securitySurfaceExclude": ["vendor/**", "late/**"] }\n'
commit_all "$REPO" "head"

# --- 1. PR mode (B-18) -------------------------------------------------------
# Added and modified files are targets, including the modified file under the
# base-commit glob (vendor/**) and the added file under the glob the PR adds
# (late/**), because no exclude list applies; the changed .enforce.json is
# itself a target. The deleted file and the untouched file are not.
run_lister "$REPO" --mode pr --base main
expect_targets "PR mode" "$(printf '%s\n' .enforce.json added.py late/excluded-by-head.py modify.py vendor/excluded.py | LC_ALL=C sort)"

# --- 2. Full mode (B-19) -----------------------------------------------------
# Every tracked HEAD file, the files the HEAD globs (vendor/**, late/**) cover
# included.
run_lister "$REPO" --mode full
expect_targets "full mode" "$(printf '%s\n' .enforce.json added.py keep.py late/excluded-by-head.py modify.py vendor/excluded.py | LC_ALL=C sort)"

# --- 3. Unresolvable base (fail closed) --------------------------------------
run_lister "$REPO" --mode pr --base no-such-branch-anywhere
expect_fail_closed "unresolvable base"

# --- 4. Unknown mode (fail closed) -------------------------------------------
run_lister "$REPO" --mode sideways
expect_fail_closed "unknown mode"

# --- 5. A path holding a space (B-18) ----------------------------------------
SPACE_REPO=$(new_repo space-path)
write_file "$SPACE_REPO" README.md $'# Space\n'
commit_all "$SPACE_REPO" "base"
git_clean -C "$SPACE_REPO" checkout -q -b feature
write_file "$SPACE_REPO" "app dir/has space.py" $'SPACED = 1\n'
write_file "$SPACE_REPO" plain.py $'PLAIN = 1\n'
commit_all "$SPACE_REPO" "add spaced file"
run_lister "$SPACE_REPO" --mode pr --base main
expect_targets "path with a space" "$(printf '%s\n' "app dir/has space.py" plain.py | LC_ALL=C sort)"

# --- 7. Base branch moved on after the branch was cut (B-18) -----------------
# The diff runs from the merge base, not from the base tip, so a file main
# gained after the PR branch was cut is not a target, and neither is the file
# main modified after the cut.
MOVED_REPO=$(new_repo moved-base)
write_file "$MOVED_REPO" shared.py $'SHARED = 1\n'
commit_all "$MOVED_REPO" "base"
git_clean -C "$MOVED_REPO" checkout -q -b feature
write_file "$MOVED_REPO" feature.py $'FEATURE = 1\n'
commit_all "$MOVED_REPO" "feature work"
git_clean -C "$MOVED_REPO" checkout -q main
write_file "$MOVED_REPO" base-only.py $'BASE_ONLY = 1\n'
write_file "$MOVED_REPO" shared.py $'SHARED = 2\n'
commit_all "$MOVED_REPO" "main moves on"
git_clean -C "$MOVED_REPO" checkout -q feature
run_lister "$MOVED_REPO" --mode pr --base main
expect_targets "base moved on" "feature.py"

# --- 8. A renamed file (B-18) ------------------------------------------------
# A file renamed on the branch with its content unchanged is listed under its
# new name only; the old name no longer exists at HEAD and is not a target.
RENAME_REPO=$(new_repo renamed-file)
write_file "$RENAME_REPO" old.py $'RENAMED_VALUE = 1\nSECOND_LINE = 2\nTHIRD_LINE = 3\n'
write_file "$RENAME_REPO" README.md $'# Rename\n'
commit_all "$RENAME_REPO" "base"
git_clean -C "$RENAME_REPO" checkout -q -b feature
git_clean -C "$RENAME_REPO" mv old.py renamed.py
commit_all "$RENAME_REPO" "rename"
run_lister "$RENAME_REPO" --mode pr --base main
expect_targets "renamed file" "renamed.py"

if [ "$failures" -gt 0 ]; then
  echo "security-ci-targets.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-ci-targets.test.sh PASS"
