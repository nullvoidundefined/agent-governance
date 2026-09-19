#!/usr/bin/env bash
# Covers: hook:ticket-at-start-gate
# Fails when a hook defines a function that a shell helper it sources also
# defines. ticket-at-start-gate.sh kept its own strip_command_prefixes (prints
# words) and then sourced shell-command-scan.sh, which since PR #79 defines one
# too (sets STRIPPED_WORDS, prints nothing). The later definition won, the gate
# read empty output and failed open on commits; each PR was green alone.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOKS="$CLAUDE_HARNESS_ROOT/hooks"
SCAN="shell-command-scan.sh"
TOKENS="shell-command-tokens.sh"

# Prints the names of the functions a file defines at column 0 as `name() {`.
list_defined_functions() { sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() {.*/\1/p' "$1"; }

# Prints "<hook>: <function>" for each helper function the hook redefines.
# A hook uses a helper when a non-comment line or a shellcheck source directive
# names it; shell-command-scan.sh sources shell-command-tokens.sh, so it
# brings both helpers' functions.
find_redefined_helper_functions() {
  local hook="$1" helper_functions="" function_name
  if grep -Eq "^[^#]*$SCAN|shellcheck source=$SCAN" "$hook"; then
    helper_functions="$(list_defined_functions "$HOOKS/$SCAN"; list_defined_functions "$HOOKS/$TOKENS")"
  elif grep -Eq "^[^#]*$TOKENS|shellcheck source=$TOKENS" "$hook"; then
    helper_functions="$(list_defined_functions "$HOOKS/$TOKENS")"
  fi
  for function_name in $(list_defined_functions "$hook"); do
    if printf '%s\n' "$helper_functions" | grep -qx "$function_name"; then
      echo "$(basename "$hook"): $function_name"
    fi
  done
}

# Self-check: a throwaway hook that redefines scan_command_tokens is flagged.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'source ./%s\nscan_command_tokens() {\n  :\n}\n' "$SCAN" >"$TMP/probe.sh"
[ "$(find_redefined_helper_functions "$TMP/probe.sh")" = "probe.sh: scan_command_tokens" ] ||
  { echo "FAIL: detector did not flag a hook redefining scan_command_tokens"; exit 1; }

REDEFINITIONS=""
for hook in "$HOOKS"/*.sh; do
  case "$(basename "$hook")" in "$SCAN" | "$TOKENS") continue ;; esac
  FOUND="$(find_redefined_helper_functions "$hook")"
  [ -z "$FOUND" ] || REDEFINITIONS+="$FOUND"$'\n'
done
if [ -n "$REDEFINITIONS" ]; then
  echo "FAIL: hooks redefine a function of a shell helper they source:"
  printf "%s" "$REDEFINITIONS"
  exit 1
fi
echo "shell-helper-redefinition.test.sh PASS"
