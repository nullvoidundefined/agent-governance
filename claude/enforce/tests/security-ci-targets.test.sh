#!/usr/bin/env bash
# Verifies the security CI scan-target lister, enforce/security-ci-targets.sh
# (IAN-381, spec Part 7 addendum, criteria B-18 and B-19). The lister runs
# with its working directory inside the repository to scan and prints the scan
# targets, one repository-relative path per line, exiting 0:
#
#   security-ci-targets.sh --mode pr --base <base-ref>
#     PR mode: every file the range <base-ref>..HEAD adds or modifies, minus
#     deleted files and minus every file that a `securitySurfaceExclude` glob
#     read from the BASE commit's `.enforce.json` covers. A glob that the PR
#     itself adds to `.enforce.json` must not exclude anything, because a PR
#     must not be able to exempt its own files from the scan.
#   security-ci-targets.sh --mode full
#     Full mode: every tracked file at HEAD that no HEAD `.enforce.json`
#     `securitySurfaceExclude` glob covers.
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
# Added and modified files are targets; the deleted file, the untouched file,
# and the file under the base-commit glob are not; the glob the PR adds
# (late/**) excludes nothing, and the changed .enforce.json is itself a target.
run_lister "$REPO" --mode pr --base main
expect_targets "PR mode" "$(printf '%s\n' .enforce.json added.py late/excluded-by-head.py modify.py | LC_ALL=C sort)"

# --- 2. Full mode (B-19) -----------------------------------------------------
# Every tracked HEAD file except those the HEAD globs (vendor/**, late/**)
# cover.
run_lister "$REPO" --mode full
expect_targets "full mode" "$(printf '%s\n' .enforce.json added.py keep.py modify.py | LC_ALL=C sort)"

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

if [ "$failures" -gt 0 ]; then
  echo "security-ci-targets.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-ci-targets.test.sh PASS"
