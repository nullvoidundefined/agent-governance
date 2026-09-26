#!/usr/bin/env bash
# security-review-ledger-path.sh: sourced helper, not a hook. The one place
# the Security review ledger's location is computed (R-109, B-10e), shared by
# enforce/security-review-record.sh, which writes the ledger, and
# hooks/git-workflow-guard.sh, which reads it at merge time, so the two can
# never disagree about which file holds a repository's records.
#
# The ledger lives outside every checkout, at
#   $HOME/.claude/security-review-ledger/<key>.json
# where <key> is the sha256 hex digest of the repository's
# `git remote get-url origin` output with no trailing newline. Every worktree
# and every clone of the same origin therefore reads and writes one ledger.
# hooks/protected-path-guard.sh spells the same directory itself, so the guard
# keeps working when this helper is missing; change both together.

# print_security_review_ledger_dir: prints the directory every repository's
# ledger file lives in; returns non-zero when HOME is unset or empty.
print_security_review_ledger_dir() {
  [ -n "${HOME:-}" ] || return 1
  printf '%s' "$HOME/.claude/security-review-ledger"
}

# print_security_review_ledger_path <directory inside a repository>: prints
# the ledger file for that repository, keyed by its `origin` URL; returns
# non-zero when the repository has no origin, when the digest cannot be
# computed, or when HOME is unset.
print_security_review_ledger_path() {
  local origin_url digest_line ledger_key ledger_dir
  origin_url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [ -n "$origin_url" ] || return 1
  digest_line=$(printf '%s' "$origin_url" | shasum -a 256) || return 1
  ledger_key="${digest_line%% *}"
  [[ "$ledger_key" =~ ^[0-9a-f]{64}$ ]] || return 1
  ledger_dir=$(print_security_review_ledger_dir) || return 1
  printf '%s/%s.json' "$ledger_dir" "$ledger_key"
}
