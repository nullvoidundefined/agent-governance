#!/usr/bin/env bash
# harness-root.sh: gives every fixture in enforce/tests/ and hooks/tests/ one
# explicit, shared answer to the question "which copy of the harness am I
# actually testing?".
#
# Until 2026-09-18 the great majority of fixtures opened their subject as
# "$HOME/.claude/hooks/<name>.sh", which is the INSTALLED copy that the last
# ./sync.sh happened to write, not the checkout that the fixture file itself
# was read from. Neither fixture runner bound that location to the checkout,
# so a local pre-push run verified whichever branch was synced most recently
# while git went on to push something else entirely, and the same fixture
# passed or failed depending on that unrelated history. Continuous integration
# symlinks the checkout into the home directory, which made the drift
# invisible there and left it to bite only on a developer's machine.
#
# Sourcing this file sets CLAUDE_HARNESS_ROOT to the harness tree under test,
# resolved in this order and never from a bare $HOME:
#
#   1. an explicit CLAUDE_HARNESS_ROOT already present in the environment, so
#      that a caller can deliberately point one run at an installed tree, at a
#      sandbox copy, or at a second checkout;
#   2. otherwise the harness tree that this helper file itself lives in,
#      derived from BASH_SOURCE. Because a fixture reaches this helper through
#      a path relative to its own BASH_SOURCE, that tree is by construction
#      the checkout the fixture was read from.
#
# The single deliberate exception in the suite is enforce/tests/hook-latency.test.sh,
# which measures the installed hooks on purpose and records why in its own
# header. Every other fixture resolves through this helper.
#
# Usage, from a fixture in either enforce/tests/ or hooks/tests/ (both sit two
# directories below the harness root, so one spelling serves both):
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
#   HOOK="$CLAUDE_HARNESS_ROOT/hooks/secret-scan.sh"
#
# CLAUDE_HARNESS_ROOT is set but deliberately not exported: a fixture that
# spawns another fixture (the implementation-root prover does exactly that)
# must be able to let the child resolve its own root rather than inherit one.
#
# Sourcing this file ALSO exports the data overrides that the hooks read at
# runtime, each defaulted to the checkout's own copy. Binding the code alone
# left half the defect standing: eleven hooks resolve a data file as
# "${SOME_OVERRIDE:-$HOME/.claude/<path>}", only a handful of fixtures ever
# set one of those variables, and so a fixture could run the checkout's
# enforcement-guard-check.sh against whatever manifest.json the last ./sync.sh
# had written. The verdict then depended on unrelated history exactly as the
# code binding did (2026-09-18, the data half of verification-integrity
# defect 3). Exporting them here means a fixture inherits both bindings from
# one source line rather than remembering eleven variable names.
#
# Two rules govern the bindings below, and both matter:
#
#   1. A value the caller already set always wins. A fixture that deliberately
#      points CLAUDE_MANIFEST_FILE at a sabotaged sandbox manifest is stating
#      the condition it wants to test, and this helper must not overwrite it.
#   2. A path the checkout does not actually carry is never exported. Several
#      of these variables name runtime state rather than tracked data, and
#      pinning those at the checkout would be worse than leaving them alone:
#      CLAUDE_FIRE_LOG and CLAUDE_SESSION_LOCK_DIR are a telemetry log and a
#      lock directory that their readers WRITE, so binding them would have the
#      fixture suites writing into the working tree; CLAUDE_MCP_DB_TARGETS and
#      CLAUDE_COLOCATED_ALLOWLIST_FILE name gitignored client-identifying
#      lists (R-106) that no checkout tracks, so binding them would swap one
#      piece of machine-specific state for another; and
#      CLAUDE_JUDGE_ACCEPT_FILE is a presence marker written when a human
#      accepts the honor-system tier, which no checkout carries either. Each
#      of those is set by the individual fixtures that care about it.

# Resolves the harness tree a fixture should test against and prints it as an
# absolute path. Honors an explicit CLAUDE_HARNESS_ROOT override first; falls
# back to the directory above the one holding this helper, which is the
# checkout's claude/ root. Runs the directory change inside a subshell so the
# caller's working directory is never disturbed.
resolve_harness_root() {
  if [ -n "${CLAUDE_HARNESS_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_HARNESS_ROOT"
    return 0
  fi
  (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

CLAUDE_HARNESS_ROOT="$(resolve_harness_root)"

# Exports one data override so the hook that reads it resolves the checkout's
# copy instead of the installed one. Takes the variable name and a path
# relative to the harness root. Declines silently in the two cases that must
# not be overridden: when the caller has already set the variable to something
# non-empty, and when the checkout does not carry the named path at all.
bind_harness_data_path() {
  local variable_name="$1" relative_path="$2" absolute_path
  absolute_path="$CLAUDE_HARNESS_ROOT/$relative_path"
  [ -z "${!variable_name:-}" ] || return 0
  [ -e "$absolute_path" ] || return 0
  # shellcheck disable=SC2163  # the assignment form of export, name in a variable
  export "$variable_name=$absolute_path"
}

# Exports one override whose value is the harness tree itself rather than a
# file inside it: hook-integrity-check.sh hashes that tree through
# CLAUDE_INTEGRITY_ROOT and enforce/tdd.sh reads role-policy.json out of it
# through CLAUDE_TDD_HOME. Declines when the caller has already set the
# variable, the same way the file bindings do.
bind_harness_tree_root() {
  local variable_name="$1"
  [ -z "${!variable_name:-}" ] || return 0
  # shellcheck disable=SC2163  # the assignment form of export, name in a variable
  export "$variable_name=$CLAUDE_HARNESS_ROOT"
}

# Exports CLAUDE_RULES_FILES, which is the one override whose value is a
# space-separated list rather than a single path: enforcement-guard-check.sh
# scans all four rulebook files for rule citations. Exports only when the
# checkout carries every one of them, because a partial list would silently
# under-report which rules cite an enforcer and the hook would go quiet about
# a real gap rather than fail loudly.
bind_harness_rule_files() {
  local rule_file rule_paths=""
  [ -z "${CLAUDE_RULES_FILES:-}" ] || return 0
  for rule_file in reference.md agents.md audits.md cost.md; do
    [ -f "$CLAUDE_HARNESS_ROOT/rulebook/$rule_file" ] || return 0
    rule_paths="$rule_paths $CLAUDE_HARNESS_ROOT/rulebook/$rule_file"
  done
  export CLAUDE_RULES_FILES="${rule_paths# }"
}

# The tracked data files that hooks read behind an override, and the two
# harness-root overrides that name the tree itself rather than one file
# (hook-integrity-check.sh hashes it, enforce/tdd.sh reads role-policy.json
# out of it). Everything listed here exists in the checkout, so every line
# binds; the deliberately absent variables are named in the header above.
bind_harness_data_path CLAUDE_MANIFEST_FILE "enforce/manifest.json"
bind_harness_data_path CLAUDE_ROLE_POLICY_FILE "enforce/role-policy.json"
bind_harness_data_path CLAUDE_SETTINGS_FILE "settings.json"
bind_harness_data_path REDACTION_GUARD_SETTINGS "settings.json"
bind_harness_data_path REDACTION_GUARD_HOOKS_DIR "hooks"
bind_harness_data_path CLAUDE_PROTOCOL_FILE "PROTOCOL.md"
bind_harness_tree_root CLAUDE_INTEGRITY_ROOT
bind_harness_tree_root CLAUDE_TDD_HOME
bind_harness_rule_files
