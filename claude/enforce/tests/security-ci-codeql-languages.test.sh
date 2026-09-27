#!/usr/bin/env bash
# Covers: ci:security-workflow
# Verifies the CodeQL language deriver, enforce/security-ci-codeql-languages.sh
# (IAN-381, spec Part 7 addendum, component 3 and criterion B-22). The script
# runs with its working directory inside the repository to scan, reads only the
# files tracked at HEAD (committed files; untracked and merely staged files do
# not count), and prints a compact JSON array of the CodeQL languages present,
# with no spaces, in the fixed order actions, go, javascript-typescript,
# python, ruby, exiting 0:
#
#   actions                any file matching ^\.github/workflows/[^/]+\.ya?ml$
#   go                     *.go
#   javascript-typescript  *.js *.jsx *.mjs *.cjs *.ts *.tsx *.mts *.cts *.vue
#   python                 *.py
#   ruby                   *.rb
#
# The script fails closed: when no supported language is tracked, or when HEAD
# does not exist because the repository has no commits, it exits 2 with nothing
# on stdout and a message on stderr, so the CI can never run CodeQL over an
# empty language list and read that as a pass. Every case compares the exact
# stdout string and the exact exit status.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
DERIVER="$CLAUDE_HARNESS_ROOT/enforce/security-ci-codeql-languages.sh"

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

# run_deriver <repo>: runs the deriver from inside the repository with the
# GIT_* variables stripped. Sets DERIVER_STDOUT, DERIVER_STDERR, and
# DERIVER_STATUS.
run_deriver() {
  local repo="$1"
  local out_file="$WORK/deriver.out" err_file="$WORK/deriver.err"
  (
    cd "$repo" || exit 96
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR \
      bash "$DERIVER"
  ) > "$out_file" 2> "$err_file"
  DERIVER_STATUS=$?
  DERIVER_STDOUT=$(cat "$out_file")
  DERIVER_STDERR=$(cat "$err_file")
}

# expect_languages <label> <expected JSON>: the last run must exit 0 and print
# exactly the expected JSON array.
expect_languages() {
  local label="$1" expected="$2"
  [ "$DERIVER_STATUS" -eq 0 ] \
    || report_failure "$label: deriver must exit 0; got $DERIVER_STATUS (stderr: ${DERIVER_STDERR:-<none>})"
  [ "$DERIVER_STDOUT" = "$expected" ] \
    || report_failure "$label: stdout must be exactly $expected; got [${DERIVER_STDOUT}]"
}

# expect_fail_closed <label>: the last run must exit 2, print nothing on
# stdout, and explain itself on stderr.
expect_fail_closed() {
  local label="$1"
  [ "$DERIVER_STATUS" -eq 2 ] || report_failure "$label: deriver must exit 2; got $DERIVER_STATUS"
  [ -z "$DERIVER_STDOUT" ] \
    || report_failure "$label: deriver must print nothing on stdout; got [${DERIVER_STDOUT}]"
  [ -n "$DERIVER_STDERR" ] || report_failure "$label: deriver must print a message on stderr"
}

[ -f "$DERIVER" ] || report_failure "precondition: $DERIVER does not exist"

# --- 1. Workflows, a Vue and TypeScript front end, and Python ----------------
# A top-level workflow file is actions; .ts and .vue both map to the single
# javascript-typescript language; the order is fixed, not discovery order.
MIXED_REPO=$(new_repo mixed)
write_file "$MIXED_REPO" .github/workflows/ci.yml $'name: ci\n'
write_file "$MIXED_REPO" server/app.py $'APP = 1\n'
write_file "$MIXED_REPO" web/src/main.ts $'export const main = 1;\n'
write_file "$MIXED_REPO" web/App.vue $'<template><div /></template>\n'
commit_all "$MIXED_REPO" "mixed"
run_deriver "$MIXED_REPO"
expect_languages "workflows, TypeScript, Vue, Python" '["actions","javascript-typescript","python"]'

# --- 2. Go and Ruby, with a non-code file beside them ------------------------
GO_RUBY_REPO=$(new_repo go-ruby)
write_file "$GO_RUBY_REPO" tool.go $'package main\n'
write_file "$GO_RUBY_REPO" lib/x.rb $'X = 1\n'
write_file "$GO_RUBY_REPO" README.md $'# Go and Ruby\n'
commit_all "$GO_RUBY_REPO" "go and ruby"
run_deriver "$GO_RUBY_REPO"
expect_languages "Go and Ruby" '["go","ruby"]'

# --- 3. No supported language (fail closed) ----------------------------------
DOCS_REPO=$(new_repo docs-only)
write_file "$DOCS_REPO" README.md $'# Docs\n'
write_file "$DOCS_REPO" docs/a.txt $'text\n'
commit_all "$DOCS_REPO" "docs only"
run_deriver "$DOCS_REPO"
expect_fail_closed "no supported language"

# --- 4. An untracked Python file does not count ------------------------------
# extra.py sits in the working tree but was never committed, so the tracked
# files at HEAD still hold no supported language.
write_file "$DOCS_REPO" extra.py $'EXTRA = 1\n'
run_deriver "$DOCS_REPO"
expect_fail_closed "untracked Python file"

# --- 5. A nested workflow directory is not a workflow ------------------------
NESTED_REPO=$(new_repo nested-workflow)
write_file "$NESTED_REPO" .github/workflows/nested/deep.yml $'name: deep\n'
write_file "$NESTED_REPO" README.md $'# Nested\n'
commit_all "$NESTED_REPO" "nested workflow"
run_deriver "$NESTED_REPO"
expect_fail_closed "nested workflow directory"

# --- 6. A repository with no commits (fail closed) ---------------------------
# A staged but uncommitted Python file must not count either: HEAD does not
# exist, so there are no tracked files at HEAD.
EMPTY_REPO=$(new_repo no-commits)
write_file "$EMPTY_REPO" staged.py $'STAGED = 1\n'
git_clean -C "$EMPTY_REPO" add -A
run_deriver "$EMPTY_REPO"
expect_fail_closed "no commits"

if [ "$failures" -gt 0 ]; then
  echo "security-ci-codeql-languages.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-ci-codeql-languages.test.sh PASS"
