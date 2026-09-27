#!/usr/bin/env bash
# Covers: ci:security-workflow
# Verifies the security CI scan-target lister, enforce/security-ci-targets.sh
# (IAN-381, spec Part 7 addendum, criteria B-18, B-19, B-25, and B-33). The
# lister runs with its working directory anywhere inside the repository to
# scan (B-33: a subdirectory prints the same set as the root) and prints the
# scan targets, one repository-relative path per line, exiting 0:
#
#   security-ci-targets.sh --mode pr --base <base-ref>
#     PR mode: every file that HEAD adds, copies, modifies, renames into, or
#     changes the type of (a symlink replaced by a regular file), relative to
#     `git merge-base <base-ref> HEAD`, minus deleted files. Every status except
#     deletion is listed (B-25). The diff starts at the merge base, so a file
#     the base branch gained after the PR branch was cut is not a target, and a
#     renamed file is listed under its new name only.
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
# The lister fails closed: when git cannot resolve the base ref, the mode or
# arguments are invalid, or any target's name holds a control character (a
# TAB or a newline, which git would otherwise quote, letting a quoted form
# stand in for another path; B-25), it exits 2 with a message on stderr and
# prints no targets. A name holding a double quote or a backslash is not a
# control character and must come through byte-for-byte, unquoted. Every case
# compares the exact sorted target set and the exact exit status, so a lister
# that over-reports or under-reports fails alike. A path holding a space must
# come through intact, because the CI passes each line to Semgrep and CodeQL
# as one file name.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
LISTER="$CLAUDE_HARNESS_ROOT/enforce/security-ci-targets.sh"

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# run_git_isolated <args...>: runs git with every GIT_* location variable
# stripped, so a fixture run from inside a hook or a worktree never touches the
# outer repo.
run_git_isolated() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR git "$@"
}

# create_repo <name>: creates a throwaway repository on branch main and prints
# its path.
create_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo"
  run_git_isolated -C "$repo" init -q --initial-branch=main
  run_git_isolated -C "$repo" config user.email t@t
  run_git_isolated -C "$repo" config user.name t
  run_git_isolated -C "$repo" config commit.gpgsign false
  printf '%s' "$repo"
}

# write_file <repo> <relative path> <content>: writes the file, creating its
# directories.
write_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

# commit_all_changes <repo> <message>: commits every change in the repository.
commit_all_changes() {
  run_git_isolated -C "$1" add -A
  run_git_isolated -C "$1" commit -q --allow-empty -m "$2"
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

# expect_closed_failure <label>: the last run must exit 2, print nothing on
# stdout, and explain itself on stderr.
expect_closed_failure() {
  local label="$1"
  [ "$LISTER_STATUS" -eq 2 ] || report_failure "$label: lister must exit 2; got $LISTER_STATUS"
  [ -z "$LISTER_STDOUT" ] \
    || report_failure "$label: lister must print no targets; got [$(printf '%s' "$LISTER_STDOUT" | tr '\n' '|')]"
  [ -n "$LISTER_STDERR" ] || report_failure "$label: lister must print a message on stderr"
}

[ -f "$LISTER" ] || report_failure "precondition: $LISTER does not exist"

# --- Shared repository for cases 1 and 2 -------------------------------------
REPO=$(create_repo pr-range)
write_file "$REPO" keep.py $'KEEP = 1\n'
write_file "$REPO" modify.py $'VALUE = 1\n'
write_file "$REPO" delete.py $'GONE = 1\n'
write_file "$REPO" vendor/excluded.py $'VENDORED = 1\n'
write_file "$REPO" .enforce.json $'{ "securitySurfaceExclude": ["vendor/**"] }\n'
commit_all_changes "$REPO" "base"
run_git_isolated -C "$REPO" checkout -q -b feature
write_file "$REPO" added.py $'ADDED = 1\n'
write_file "$REPO" modify.py $'VALUE = 2\n'
write_file "$REPO" vendor/excluded.py $'VENDORED = 2\n'
rm "$REPO/delete.py"
write_file "$REPO" late/excluded-by-head.py $'LATE = 1\n'
write_file "$REPO" .enforce.json $'{ "securitySurfaceExclude": ["vendor/**", "late/**"] }\n'
commit_all_changes "$REPO" "head"

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

# --- 2b. Run from a subdirectory (B-33) --------------------------------------
# Run from the tracked subdirectory vendor/, both modes print exactly the
# repository-relative sets cases 1 and 2 expect from the root.
[ -d "$REPO/vendor" ] || report_failure "precondition: $REPO/vendor must exist"
run_lister "$REPO/vendor" --mode pr --base main
expect_targets "PR mode from vendor/" "$(printf '%s\n' .enforce.json added.py late/excluded-by-head.py modify.py vendor/excluded.py | LC_ALL=C sort)"
run_lister "$REPO/vendor" --mode full
expect_targets "full mode from vendor/" "$(printf '%s\n' .enforce.json added.py keep.py late/excluded-by-head.py modify.py vendor/excluded.py | LC_ALL=C sort)"

# --- 3. Unresolvable base (fail closed) --------------------------------------
run_lister "$REPO" --mode pr --base no-such-branch-anywhere
expect_closed_failure "unresolvable base"

# --- 4. Unknown mode (fail closed) -------------------------------------------
run_lister "$REPO" --mode sideways
expect_closed_failure "unknown mode"

# --- 5. A path holding a space (B-18) ----------------------------------------
SPACE_REPO=$(create_repo space-path)
write_file "$SPACE_REPO" README.md $'# Space\n'
commit_all_changes "$SPACE_REPO" "base"
run_git_isolated -C "$SPACE_REPO" checkout -q -b feature
write_file "$SPACE_REPO" "app dir/has space.py" $'SPACED = 1\n'
write_file "$SPACE_REPO" plain.py $'PLAIN = 1\n'
commit_all_changes "$SPACE_REPO" "add spaced file"
run_lister "$SPACE_REPO" --mode pr --base main
expect_targets "path with a space" "$(printf '%s\n' "app dir/has space.py" plain.py | LC_ALL=C sort)"

# --- 7. Base branch moved on after the branch was cut (B-18) -----------------
# The diff runs from the merge base, not from the base tip, so a file main
# gained after the PR branch was cut is not a target, and neither is the file
# main modified after the cut.
MOVED_REPO=$(create_repo moved-base)
write_file "$MOVED_REPO" shared.py $'SHARED = 1\n'
commit_all_changes "$MOVED_REPO" "base"
run_git_isolated -C "$MOVED_REPO" checkout -q -b feature
write_file "$MOVED_REPO" feature.py $'FEATURE = 1\n'
commit_all_changes "$MOVED_REPO" "feature work"
run_git_isolated -C "$MOVED_REPO" checkout -q main
write_file "$MOVED_REPO" base-only.py $'BASE_ONLY = 1\n'
write_file "$MOVED_REPO" shared.py $'SHARED = 2\n'
commit_all_changes "$MOVED_REPO" "main moves on"
run_git_isolated -C "$MOVED_REPO" checkout -q feature
run_lister "$MOVED_REPO" --mode pr --base main
expect_targets "base moved on" "feature.py"

# --- 8. A renamed file (B-18) ------------------------------------------------
# A file renamed on the branch with its content unchanged is listed under its
# new name only; the old name no longer exists at HEAD and is not a target.
RENAME_REPO=$(create_repo renamed-file)
write_file "$RENAME_REPO" old.py $'RENAMED_VALUE = 1\nSECOND_LINE = 2\nTHIRD_LINE = 3\n'
write_file "$RENAME_REPO" README.md $'# Rename\n'
commit_all_changes "$RENAME_REPO" "base"
run_git_isolated -C "$RENAME_REPO" checkout -q -b feature
run_git_isolated -C "$RENAME_REPO" mv old.py renamed.py
commit_all_changes "$RENAME_REPO" "rename"
run_lister "$RENAME_REPO" --mode pr --base main
expect_targets "renamed file" "renamed.py"

# --- 9. A type change: a symlink replaced by a regular file (B-25) -----------
# The base holds cors.py as a symlink to target.txt; the PR replaces the link
# with a regular file of the same name. git reports that as a type change (T),
# which is not a deletion, so cors.py is a target; target.txt is unchanged and
# is not.
TYPE_REPO=$(create_repo type-change)
write_file "$TYPE_REPO" target.txt $'LINKED = 1\n'
ln -s target.txt "$TYPE_REPO/cors.py"
commit_all_changes "$TYPE_REPO" "base with a symlink"
[ -L "$TYPE_REPO/cors.py" ] || report_failure "precondition: cors.py must be a symlink at the base commit"
run_git_isolated -C "$TYPE_REPO" checkout -q -b feature
rm "$TYPE_REPO/cors.py"
write_file "$TYPE_REPO" cors.py $'ALLOWED_ORIGINS = ["*"]\n'
commit_all_changes "$TYPE_REPO" "replace the symlink with a regular file"
TYPE_STATUS=$(run_git_isolated -C "$TYPE_REPO" diff --name-status --no-renames main HEAD)
[ "$TYPE_STATUS" = "$(printf 'T\tcors.py')" ] \
  || report_failure "precondition: git must report cors.py as a type change; got [$TYPE_STATUS]"
run_lister "$TYPE_REPO" --mode pr --base main
expect_targets "symlink replaced by a regular file" "cors.py"

# --- 10. A name holding a TAB fails closed (B-25) ----------------------------
TAB_NAME=$(printf 'a\tb.py')
TAB_REPO=$(create_repo tab-name)
write_file "$TAB_REPO" README.md $'# Tab\n'
commit_all_changes "$TAB_REPO" "base"
run_git_isolated -C "$TAB_REPO" checkout -q -b feature
write_file "$TAB_REPO" "$TAB_NAME" $'TABBED = 1\n'
write_file "$TAB_REPO" plain.py $'PLAIN = 1\n'
commit_all_changes "$TAB_REPO" "add a tab-named file"
[ -f "$TAB_REPO/$TAB_NAME" ] || report_failure "precondition: the tab-named file must exist"
run_lister "$TAB_REPO" --mode pr --base main
expect_closed_failure "name holding a TAB, PR mode"
run_lister "$TAB_REPO" --mode full
expect_closed_failure "name holding a TAB, full mode"

# --- 11. A name holding a newline fails closed (B-25) ------------------------
# The trailing `x` keeps command substitution from stripping the newline.
NEWLINE_NAME=$(printf 'c\nd.pyx')
NEWLINE_NAME="${NEWLINE_NAME%x}"
NEWLINE_REPO=$(create_repo newline-name)
write_file "$NEWLINE_REPO" README.md $'# Newline\n'
commit_all_changes "$NEWLINE_REPO" "base"
run_git_isolated -C "$NEWLINE_REPO" checkout -q -b feature
write_file "$NEWLINE_REPO" "$NEWLINE_NAME" $'NEWLINED = 1\n'
write_file "$NEWLINE_REPO" plain.py $'PLAIN = 1\n'
commit_all_changes "$NEWLINE_REPO" "add a newline-named file"
[ -f "$NEWLINE_REPO/$NEWLINE_NAME" ] || report_failure "precondition: the newline-named file must exist"
run_lister "$NEWLINE_REPO" --mode pr --base main
expect_closed_failure "name holding a newline, PR mode"

# --- 12. Names holding a double quote and a backslash come through intact ----
# Neither is a control character, so the lister lists both, byte-for-byte and
# without git's C-style quoting (B-25: every status except deletion listed,
# and a quoted form never substitutes for the real path).
QUOTE_REPO=$(create_repo quote-backslash)
write_file "$QUOTE_REPO" README.md $'# Quote\n'
commit_all_changes "$QUOTE_REPO" "base"
run_git_isolated -C "$QUOTE_REPO" checkout -q -b feature
write_file "$QUOTE_REPO" 'we"ird.py' $'QUOTED = 1\n'
write_file "$QUOTE_REPO" 'back\slash.py' $'BACKSLASHED = 1\n'
commit_all_changes "$QUOTE_REPO" "add quote and backslash names"
run_lister "$QUOTE_REPO" --mode pr --base main
expect_targets "double quote and backslash, PR mode" "$(printf '%s\n' 'we"ird.py' 'back\slash.py' | LC_ALL=C sort)"
run_lister "$QUOTE_REPO" --mode full
expect_targets "double quote and backslash, full mode" "$(printf '%s\n' README.md 'we"ird.py' 'back\slash.py' | LC_ALL=C sort)"

if [ "$failures" -gt 0 ]; then
  echo "security-ci-targets.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-ci-targets.test.sh PASS"
