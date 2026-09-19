#!/usr/bin/env bash
# Covers: hook:ticket-at-start-gate
# Fails when a hook defines a function, or assigns a constant, that a shell
# helper it sources also defines. ticket-at-start-gate.sh kept its own
# strip_command_prefixes (prints words) and then sourced shell-command-scan.sh,
# which since PR #79 defines one too (sets STRIPPED_WORDS, prints nothing). The
# later definition won, the gate read empty output and failed open on commits;
# each PR was green alone. A constant such as REDIRECTION_PATTERN collides the
# same way: whichever assignment runs last changes the other file's behavior.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOKS="$CLAUDE_HARNESS_ROOT/hooks"
SCAN="shell-command-scan"
TOKENS="shell-command-tokens"
NAME='[A-Za-z_][A-Za-z0-9_]*'

# Prints the names of the functions a file defines in any shape: optional
# indentation, `function name`, `function name()`, or `name()` (the parentheses
# are required without the keyword), then `{`, `(`, or end of line.
list_defined_functions() {
  sed -En -e "s/^[[:space:]]*function[[:space:]]+($NAME)[[:space:]]*(\(\))?[[:space:]]*([{(].*)?\$/\1/p" \
    -e "s/^[[:space:]]*($NAME)[[:space:]]*\(\)[[:space:]]*([{(].*)?\$/\1/p" "$1"
}

# Prints the constants a helper assigns at column 0 (`NAME=`).
list_helper_constants() { sed -En "s/^($NAME)=.*/\1/p" "$1"; }

# Prints the names a hook assigns without `local`, at column 0 or indented,
# optionally behind `export` or `readonly`.
list_assigned_names() {
  sed -En "s/^[[:space:]]*((export|readonly)[[:space:]]+)?($NAME)=.*/\3/p" "$1"
}

# Prints the functions and constants of one helper, one name per line.
list_helper_names() { list_defined_functions "$HOOKS/$1.sh"; list_helper_constants "$HOOKS/$1.sh"; }

# Prints "<hook>: <name>" for each helper function or constant the hook redefines.
# A hook uses a helper when a non-comment line or a shellcheck source directive
# names it, with or without `.sh`; shell-command-scan sources
# shell-command-tokens, so it brings both helpers' names.
find_redefined_helper_names() {
  local hook="$1" helper_names="" hook_names name
  if grep -Eq "^[^#]*$SCAN|shellcheck source=[^ ]*$SCAN" "$hook"; then
    helper_names="$(list_helper_names "$SCAN"; list_helper_names "$TOKENS")"
  elif grep -Eq "^[^#]*$TOKENS|shellcheck source=[^ ]*$TOKENS" "$hook"; then
    helper_names="$(list_helper_names "$TOKENS")"
  fi
  hook_names="$(list_defined_functions "$hook"; list_assigned_names "$hook")"
  for name in $(printf '%s\n' "$hook_names" | sort -u); do
    if printf '%s\n' "$helper_names" | grep -qx "$name"; then echo "$(basename "$hook"): $name"; fi
  done
}

# expect_flag <expected> <probe body>: the detector prints exactly <expected> for a probe hook.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
expect_flag() {
  printf '%s\n' "$2" >"$TMP/probe.sh"
  [ "$(find_redefined_helper_names "$TMP/probe.sh")" = "$1" ] ||
    { echo "FAIL: self-check expected '$1' for probe:"; printf '%s\n' "$2"; exit 1; }
}
USES_SCAN="source ./$SCAN.sh"
for shape in 'scan_command_tokens(){' 'scan_command_tokens () {' 'function scan_command_tokens {' \
  'function scan_command_tokens() {' 'scan_command_tokens() (' '  scan_command_tokens() {' \
  $'scan_command_tokens()\n{'; do
  expect_flag "probe.sh: scan_command_tokens" "$USES_SCAN"$'\n'"$shape"$'\n  :\n}'
done
expect_flag "probe.sh: REDIRECTION_PATTERN" "$USES_SCAN"$'\nREDIRECTION_PATTERN=x'
expect_flag "probe.sh: HEREDOC_TOKEN" "$USES_SCAN"$'\nf() {\n  HEREDOC_TOKEN=x\n}'
expect_flag "" "$USES_SCAN"$'\nf() {\n  local HEREDOC_TOKEN=x\n}'
expect_flag "probe.sh: scan_command_tokens" $'h='"$SCAN"$'\n. "$DIR/$h.sh"\nscan_command_tokens() {\n  :\n}'

REDEFINITIONS=""
for hook in "$HOOKS"/*.sh; do
  case "$(basename "$hook")" in "$SCAN.sh" | "$TOKENS.sh") continue ;; esac
  FOUND="$(find_redefined_helper_names "$hook")"
  [ -z "$FOUND" ] || REDEFINITIONS+="$FOUND"$'\n'
done
if [ -n "$REDEFINITIONS" ]; then
  echo "FAIL: hooks redefine a function or constant of a shell helper they source:"
  printf "%s" "$REDEFINITIONS"
  exit 1
fi
echo "shell-helper-redefinition.test.sh PASS"
