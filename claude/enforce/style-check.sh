#!/usr/bin/env bash
# style-check.sh: PR-scoped style check on the lines a change adds to shell files.
#
# Usage: style-check.sh [--base <ref>] [--repo <dir>]
#   --base  the commit to compare with (default origin/main); the check looks at
#           the lines `git diff <base>...HEAD` adds.
#   --repo  the repository to check (default: the current directory).
#
# Scope: only *.sh files are checked, and only the lines the change adds, so old
# code never fails it. Paths with a tests/ directory or node_modules/ are skipped.
# Checks on each added line:
#   - width: more than 100 characters (a tab counts as one);
#   - a function definition with no comment line directly above it (the brace
#     may be on the same or the next line);
#   - shellcheck -S warning findings (skipped with a warning when shellcheck is
#     not installed).
# Output: one `<file>:<line>:<message>` per violation, sorted, then
# `style-check: <n> violation(s)`; a clean run prints only `style-check: ok`.
# Exit codes: 0 clean, 1 violations, 2 usage error or a diff that cannot be read
# (a diff that fails never counts as clean).
set -uo pipefail

SEP=$'\037'
BASE="origin/main"
REPO="."
WORK=""

# usage_error <message>: prints the message and the usage line to stderr, exit 2.
usage_error() {
  echo "style-check: $1" >&2
  echo "usage: style-check.sh [--base <ref>] [--repo <dir>]" >&2
  exit 2
}

# parse_flags <args...>: sets BASE and REPO from the flags.
parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --base | --repo)
        [ $# -ge 2 ] || usage_error "$1 needs a value"
        if [ "$1" = "--base" ]; then BASE="$2"; else REPO="$2"; fi
        shift 2 ;;
      *) usage_error "unknown argument $1" ;;
    esac
  done
}

# validate_inputs: checks that REPO is a git repository and BASE is a commit.
validate_inputs() {
  [ -d "$REPO" ] || usage_error "--repo is not a directory"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 ||
    usage_error "--repo is not a git repository"
  git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 ||
    usage_error "--base is not a commit in the repository"
}

# collect_diff: writes the added-lines diff to $WORK/diff.txt; a diff that
# fails (no merge base, shallow history) exits 2 and never reports clean.
collect_diff() {
  # The prefixes and --no-ext-diff pin the diff format against the repo's own
  # diff.noprefix and diff.external config, which would change the file headers.
  if ! git -C "$REPO" -c core.quotepath=false diff -M --unified=0 --no-color \
    --src-prefix=a/ --dst-prefix=b/ --no-ext-diff \
    "$BASE...HEAD" -- '*.sh' >"$WORK/diff.txt" 2>"$WORK/diff.err"; then
    echo "style-check: cannot diff $BASE...HEAD: $(head -n 1 "$WORK/diff.err")" >&2
    exit 2
  fi
}

# extract_added_lines: prints "<file>SEP<line>SEP<text>" for every added line.
# File headers are only recognised before the first hunk of a file, so an added
# content line that starts with "++ " is never taken for one. A path git quotes
# is printed as a "?" marker line instead of being skipped.
extract_added_lines() {
  awk -v sep="$SEP" '
    /^diff --git / { inhdr = 1; file = ""; next }
    inhdr && /^\+\+\+ "/ { print "?" sep "0" sep $0; file = ""; next }
    inhdr && /^\+\+\+ b\// { file = substr($0, 7); sub(/\t$/, "", file); next }
    inhdr && /^\+\+\+ / { file = ""; next }
    /^@@/ {
      inhdr = 0
      match($0, /\+[0-9]+/)
      ln = substr($0, RSTART + 1, RLENGTH - 1) + 0
      next
    }
    inhdr { next }
    /^\+/ { if (file != "") print file sep ln sep substr($0, 2); ln++ }
  ' "$WORK/diff.txt"
}

# select_scope: keeps added lines of files in scope (not under tests/ or
# node_modules/) in $WORK/added.txt; exits 2 on a path it cannot parse.
select_scope() {
  extract_added_lines >"$WORK/all.txt"
  if grep -q "^?$SEP" "$WORK/all.txt"; then
    echo "style-check: cannot parse a quoted path in the diff" >&2
    exit 2
  fi
  awk -F"$SEP" '$1 !~ /(^|\/)tests\// && $1 !~ /(^|\/)node_modules\//' \
    "$WORK/all.txt" >"$WORK/added.txt"
}

# add_violation <file> <line> <message>: records one violation.
add_violation() {
  echo "$1:$2:$3" >>"$WORK/violations.txt"
}

# check_width: reports added lines longer than 100 characters.
check_width() {
  local file ln text len
  while IFS="$SEP" read -r file ln text; do
    len=${#text}
    [ "$len" -le 100 ] || add_violation "$file" "$ln" "line is $len columns (max 100)"
  done <"$WORK/added.txt"
}

# function_name <line>: prints the function name defined on the line, or
# nothing when the line is not a function definition. Definitions are
# `name() {`, `function name {`, `function name() {`, and the same with the
# brace on the next line.
function_name() {
  local name='[a-zA-Z_][a-zA-Z0-9_]*' ws='[[:space:]]*' brace="(\\{.*)?"
  local plain="^${ws}(function[[:space:]]+)?${name}${ws}\\(\\)${ws}${brace}$"
  local keyword="^${ws}function[[:space:]]+${name}${ws}${brace}$"
  if printf '%s\n' "$1" | grep -qE "${plain}|${keyword}"; then
    printf '%s\n' "$1" |
      sed -E 's/^[[:space:]]*(function[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_]*).*/\2/'
  fi
}

# check_function_comments: reports added function definitions whose
# preceding line (at HEAD) is not a comment.
check_function_comments() {
  local file ln text name prev
  while IFS="$SEP" read -r file ln text; do
    name=$(function_name "$text")
    [ -n "$name" ] || continue
    prev=""
    if [ "$ln" -gt 1 ]; then
      prev=$(git -C "$REPO" show "HEAD:$file" 2>/dev/null | sed -n "$((ln - 1))p")
    fi
    printf '%s\n' "$prev" | grep -qE '^[[:space:]]*#' ||
      add_violation "$file" "$ln" "function $name has no comment block above it"
  done <"$WORK/added.txt"
}

# check_shellcheck: runs shellcheck on the changed files from the repo root
# and keeps only the findings on added lines.
check_shellcheck() {
  local file key rest
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "style-check: warning: shellcheck not installed, skipped" >&2
    return 0
  fi
  awk -F"$SEP" '{ print $1 ":" $2 }' "$WORK/added.txt" >"$WORK/keys.txt"
  cut -d"$SEP" -f1 "$WORK/added.txt" | sort -u >"$WORK/files.txt"
  : >"$WORK/shellcheck.txt"
  while IFS= read -r file; do
    ( cd "$REPO" && shellcheck -S warning -x -f gcc -- "$file" 2>/dev/null ) \
      >>"$WORK/shellcheck.txt" || true
  done <"$WORK/files.txt"
  while IFS= read -r rest; do
    key=$(printf '%s\n' "$rest" | sed -E 's/^(.*:[0-9]+):[0-9]+: .*$/\1/')
    if grep -Fxq -- "$key" "$WORK/keys.txt"; then
      printf '%s\n' "$rest" |
        sed -E 's/^(.*:[0-9]+):[0-9]+: (.*)$/\1:\2/' >>"$WORK/violations.txt"
    fi
  done <"$WORK/shellcheck.txt"
}

# print_report: prints the sorted violations and the summary; returns the
# exit status (0 clean, 1 violations).
print_report() {
  if [ -s "$WORK/violations.txt" ]; then
    sort -t: -k1,1 -k2,2n "$WORK/violations.txt"
    echo "style-check: $(wc -l <"$WORK/violations.txt" | tr -d ' ') violation(s)"
    return 1
  fi
  echo "style-check: ok"
  return 0
}

parse_flags "$@"
validate_inputs
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
collect_diff
select_scope
: >"$WORK/violations.txt"
check_width
check_function_comments
check_shellcheck
print_report
exit $?
