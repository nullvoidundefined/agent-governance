#!/usr/bin/env bash
# style-check.sh: PR-scoped style check on added lines of shell files.
# Usage: style-check.sh [--base <ref>] [--repo <dir>]
# Checks: width >100, function comment blocks, shellcheck on added lines.
set -euo pipefail

BASE="origin/main"
REPO="."

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      shift
      if [ $# -eq 0 ]; then
        echo "usage: style-check.sh [--base <ref>] [--repo <dir>]" >&2
        exit 2
      fi
      BASE="$1"; shift ;;
    --repo)
      shift
      if [ $# -eq 0 ]; then
        echo "usage: style-check.sh [--base <ref>] [--repo <dir>]" >&2
        exit 2
      fi
      REPO="$1"; shift ;;
    *)
      echo "usage: style-check.sh [--base <ref>] [--repo <dir>]" >&2
      exit 2 ;;
  esac
done

# Validate --base is a commit (in the repo)
git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 || {
  echo "usage: style-check.sh [--base <ref>] [--repo <dir>]" >&2
  exit 2
}

# Validate --repo is a git repository
if [ ! -d "$REPO" ]; then
  echo "usage: style-check.sh [--base <ref>] [--repo <dir>]" >&2
  exit 2
fi
( cd "$REPO" && git rev-parse --git-dir >/dev/null 2>&1 ) || {
  echo "usage: style-check.sh [--base <ref>] [--repo <dir>]" >&2
  exit 2
}

# Create temp directory
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Get added lines from diff
git -C "$REPO" diff -M --unified=0 --no-color "$BASE...HEAD" -- '*.sh' \
  >"$TMPDIR_WORK/diff.txt" 2>/dev/null || true

# extract_added_lines: parse the diff to get file, line number, and text
# for every added line, using the canonical awk program.
extract_added_lines() {
  # Uses the canonical awk program to produce file<TAB>line<TAB>text
  # for every added line in the diff output.
  awk '
/^\+\+\+ b\// { file = substr($0, 7); next }
/^\+\+\+ /    { file = ""; next }
/^@@/         { match($0, /\+[0-9]+/); ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
/^\+/         { if (file != "") print file "\t" ln "\t" substr($0, 2); ln++ }
' "$TMPDIR_WORK/diff.txt"
}

extract_added_lines >"$TMPDIR_WORK/added_lines.txt"

# Filter out tests/ and node_modules/
grep -vE '(^|/)tests/' "$TMPDIR_WORK/added_lines.txt" | \
grep -vE '(^|/)node_modules/' >"$TMPDIR_WORK/filtered_lines.txt" 2>/dev/null || true

# Build a keys file for shellcheck filtering (file:line)
cut -f1,2 "$TMPDIR_WORK/filtered_lines.txt" | \
  awk -F'\t' '{ print $1 ":" $2 }' >"$TMPDIR_WORK/added_keys.txt" 2>/dev/null || true

# Initialize violations file
> "$TMPDIR_WORK/violations.txt"

# Check 1: width > 100
while IFS=$'\t' read -r file ln text; do
  if [ -z "$file" ]; then continue; fi
  len=${#text}
  if [ "$len" -gt 100 ]; then
    echo "${file}:${ln}:line is ${len} columns (max 100)" >>"$TMPDIR_WORK/violations.txt"
  fi
done <"$TMPDIR_WORK/filtered_lines.txt"

# is_function_def: check if a line defines a function
# Returns 0 (true) if the line matches a function definition pattern.
is_function_def() {
  local line="$1"
  # Match: name() {, function name {, function name() {, with optional leading whitespace
  if echo "$line" | grep -qE '^[[:space:]]*(function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)|^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\))[[:space:]]*\{'; then
    return 0
  fi
  if echo "$line" | grep -qE '^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\{'; then
    return 0
  fi
  return 1
}

# extract_func_name: extract the function name from a definition line
extract_func_name() {
  local line="$1"
  echo "$line" | sed 's/^[[:space:]]*//; s/^function[[:space:]]*//; s/()[[:space:]]*{.*//; s/[[:space:]]*{.*//'
}

# Check 2: function comment blocks
while IFS=$'\t' read -r file ln text; do
  if [ -z "$file" ]; then continue; fi
  if is_function_def "$text"; then
    func_name=$(extract_func_name "$text")
    if [ "$ln" -le 1 ]; then
      echo "$file:$ln:function $func_name has no comment block above it" >>"$TMPDIR_WORK/violations.txt"
    else
      prev_ln=$((ln - 1))
      prev_line=$(git -C "$REPO" show HEAD:"$file" 2>/dev/null | sed -n "${prev_ln}p")
      if echo "$prev_line" | grep -qE '^[[:space:]]*#'; then
        :
      else
        echo "$file:$ln:function $func_name has no comment block above it" >>"$TMPDIR_WORK/violations.txt"
      fi
    fi
  fi
done <"$TMPDIR_WORK/filtered_lines.txt"

# Check 3: shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  # Get unique files with added lines
  cut -f1 "$TMPDIR_WORK/filtered_lines.txt" | sort -u >"$TMPDIR_WORK/files.txt"

  # For each file, run shellcheck and filter to added lines
  while read -r file; do
    if [ -z "$file" ]; then continue; fi
    shellcheck -S warning -x -f gcc "$REPO/$file" 2>/dev/null | \
    while IFS=: read -r sc_file sc_ln sc_rest; do
      # Check if this file:line is an added line
      if grep -Fx "$sc_file:$sc_ln" "$TMPDIR_WORK/added_keys.txt" >/dev/null 2>&1; then
        echo "$sc_file:$sc_ln:$sc_rest"
      fi
    done >>"$TMPDIR_WORK/violations.txt"
  done <"$TMPDIR_WORK/files.txt"
else
  echo "style-check: warning: shellcheck not installed, skipped" >&2
fi

# Sort violations by file then line number
if [ -s "$TMPDIR_WORK/violations.txt" ]; then
  sort -t: -k1,1 -k2,2n "$TMPDIR_WORK/violations.txt"
  count=$(wc -l <"$TMPDIR_WORK/violations.txt" | tr -d ' ')
  echo "style-check: $count violation(s)"
  exit 1
fi

echo "style-check: ok"
exit 0
