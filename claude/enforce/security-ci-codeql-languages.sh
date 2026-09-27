#!/usr/bin/env bash
# security-ci-codeql-languages.sh: derives the CodeQL language list for the
# reusable security CI workflow (.github/workflows/security.yml; IAN-381 Part
# 7, B-22) from the files tracked at HEAD of the repository in the working
# directory, so a caller cannot soften the gate by naming fewer languages.
#
# Prints a compact JSON array in a fixed order, drawn from `actions` (any file
# under .github/workflows/), `go`, `javascript-typescript`, `python`, and
# `ruby`, and exits 0. Exits 2 with a message on stderr when git cannot list
# HEAD or no supported language is present, because an empty matrix would
# skip CodeQL and GitHub counts a skipped job as passing. bash 3.2 compatible.
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

# main: prints the language array or fails closed.
main() {
  local tracked_files language_lines
  tracked_files=$(git -c core.quotePath=false ls-tree -r --name-only HEAD 2>/dev/null) \
    || exit_with_failure "git could not list the files tracked at HEAD"
  language_lines=$(list_present_languages "$tracked_files")
  [ -n "$language_lines" ] || exit_with_failure "no CodeQL-supported language is tracked here"
  printf '%s\n' "$language_lines" | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

main "$@"
