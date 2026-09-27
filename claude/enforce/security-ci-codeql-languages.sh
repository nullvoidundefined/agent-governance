#!/usr/bin/env bash
# security-ci-codeql-languages.sh: derives the CodeQL language list for the
# reusable security CI workflow (.github/workflows/security.yml; IAN-381 Part
# 7, B-22 and B-28) from the files tracked at HEAD of the repository in the
# working directory, so a caller cannot soften the gate by naming fewer
# languages.
#
#   security-ci-codeql-languages.sh --mode pr
#   security-ci-codeql-languages.sh --mode full
#
# Prints a compact JSON array in a fixed order, drawn from `actions` (any file
# directly under .github/workflows/), `go`, `javascript-typescript`,
# `python`, and `ruby`, and exits 0. In PR mode `go` is never listed, and a
# `::notice::` on stderr says so: CodeQL can analyze Go only by running the
# repository's own build, and a PR's code must never run beside the
# code-scanning write token (owner decision 2026-09-27); full mode runs on
# already-merged code and lists it. Exits 2 with a message on stderr when the
# mode is missing or unknown, git cannot list HEAD, or no language remains,
# because an empty matrix would skip CodeQL and GitHub counts a skipped job as
# passing. bash 3.2 compatible.
set -uo pipefail

# exit_with_failure <message>: reports why no language list can be trusted and
# exits 2.
exit_with_failure() {
  printf 'security-ci-codeql-languages: %s; failing closed.\n' "$1" >&2
  exit 2
}

# list_present_languages <tracked files>: prints each supported CodeQL
# language with at least one matching tracked file, one per line, in the fixed
# order.
list_present_languages() {
  local tracked_files="$1"
  printf '%s\n' "$tracked_files" | grep -Eq '^\.github/workflows/[^/]+\.ya?ml$' && echo actions
  printf '%s\n' "$tracked_files" | grep -Eq '\.go$' && echo go
  printf '%s\n' "$tracked_files" | grep -Eq '\.(js|jsx|mjs|cjs|ts|tsx|mts|cts|vue)$' && echo javascript-typescript
  printf '%s\n' "$tracked_files" | grep -Eq '\.py$' && echo python
  printf '%s\n' "$tracked_files" | grep -Eq '\.rb$' && echo ruby
  return 0
}

# drop_go_for_pr <language lines>: prints the lines without `go`, with a
# notice on stderr when `go` was present.
drop_go_for_pr() {
  local language_lines="$1"
  if printf '%s\n' "$language_lines" | grep -qx go; then
    echo "::notice::CodeQL skips go on pull requests, because analyzing Go runs the repository's own build; go is analyzed on push to the default branch, and Semgrep still scans it here." >&2
  fi
  printf '%s\n' "$language_lines" | grep -vx go
  return 0
}

# main: prints the language array for the chosen mode, or fails closed.
main() {
  local scan_mode tracked_files language_lines
  [ "$#" -eq 2 ] && [ "$1" = "--mode" ] || exit_with_failure "usage: --mode pr|full"
  scan_mode="$2"
  case "$scan_mode" in pr|full) ;; *) exit_with_failure "--mode must be pr or full, not '$scan_mode'" ;; esac
  cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit_with_failure "not inside a git work tree"
  tracked_files=$(git -c core.quotePath=false ls-tree -r --name-only HEAD 2>/dev/null) \
    || exit_with_failure "git could not list the files tracked at HEAD"
  language_lines=$(list_present_languages "$tracked_files")
  [ "$scan_mode" = "pr" ] && language_lines=$(drop_go_for_pr "$language_lines")
  [ -n "$language_lines" ] || exit_with_failure "no CodeQL language remains to analyze"
  printf '%s\n' "$language_lines" | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

main "$@"
