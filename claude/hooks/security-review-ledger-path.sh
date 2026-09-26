#!/usr/bin/env bash
# security-review-ledger-path.sh: sourced helper, not a hook. The one place
# the Security review ledger's location is computed (R-109, B-10e), shared by
# enforce/security-review-record.sh, which writes the ledger, and
# hooks/git-workflow-guard.sh, which reads it at merge time, so the two can
# never disagree about which file holds a repository's records.
#
# The ledger lives outside every checkout, at
#   $HOME/.claude/security-review-ledger/<key>.json
# where <key> is the sha256 hex digest, with no trailing newline, of the
# repository identity `host/owner/repo` (B-10f). The identity is the origin
# URL lowercased, with its scheme, any `user@`, any port, a trailing slash,
# and a `.git` suffix removed, so https://github.com/o/r,
# git@github.com:o/r.git, and ssh://git@github.com/o/r all key one file. Every
# worktree and every clone of the same repository therefore reads and writes
# one ledger, whichever spelling its origin uses. A URL that does not reduce
# to exactly a host and two path segments (a file path, for one) has no
# identity, and every caller refuses rather than guessing.
# hooks/protected-path-guard.sh spells the same directory itself, so the guard
# keeps working when this helper is missing; change both together.

# URL shapes the identity is read from: `scheme://authority/path` and the
# scp-like `[user@]host:path`, whose host holds no slash.
SECURITY_REVIEW_URL_WITH_SCHEME='^[a-z][a-z0-9+.-]*://([^/]*)/(.*)$'
SECURITY_REVIEW_URL_SCP_LIKE='^([^@/:]+@)?([^/:]+):(.*)$'
# The pieces an identity is built from: a host name and one path segment.
SECURITY_REVIEW_HOST_PATTERN='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'
SECURITY_REVIEW_SEGMENT_PATTERN='^[a-z0-9._-]+$'

# print_security_review_ledger_dir: prints the directory every repository's
# ledger file lives in; returns non-zero when HOME is unset or empty.
print_security_review_ledger_dir() {
  [ -n "${HOME:-}" ] || return 1
  printf '%s' "$HOME/.claude/security-review-ledger"
}

# print_repository_identity <url>: prints the normalized identity
# `host/owner/repo` of a repository URL written as
# `scheme://[user@]host[:port]/owner/repo[.git]` or scp-like as
# `[user@]host:owner/repo[.git]`, lowercased, with a trailing slash and a
# `.git` suffix removed; returns non-zero, printing nothing, when the URL does
# not reduce to exactly a host and two path segments.
print_repository_identity() {
  local lowered_url authority host repository_path owner repository
  lowered_url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') || return 1
  if [[ "$lowered_url" =~ $SECURITY_REVIEW_URL_WITH_SCHEME ]]; then
    authority="${BASH_REMATCH[1]##*@}"
    host="${authority%%:*}"
    repository_path="${BASH_REMATCH[2]}"
  elif [[ "$lowered_url" =~ $SECURITY_REVIEW_URL_SCP_LIKE ]]; then
    host="${BASH_REMATCH[2]}"
    repository_path="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  repository_path="${repository_path%/}"
  repository_path="${repository_path%.git}"
  [[ "$repository_path" == */* ]] || return 1
  owner="${repository_path%%/*}"
  repository="${repository_path#*/}"
  [[ "$host" =~ $SECURITY_REVIEW_HOST_PATTERN ]] || return 1
  [[ "$owner" =~ $SECURITY_REVIEW_SEGMENT_PATTERN ]] || return 1
  [[ "$repository" =~ $SECURITY_REVIEW_SEGMENT_PATTERN ]] || return 1
  printf '%s/%s/%s' "$host" "$owner" "$repository"
}

# print_origin_repository_identity <directory inside a repository>: prints the
# normalized identity of the repository's `origin` fetch URL; returns non-zero
# when there is no origin or its URL has no identity.
print_origin_repository_identity() {
  local origin_url
  origin_url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [ -n "$origin_url" ] || return 1
  print_repository_identity "$origin_url"
}

# print_security_review_ledger_path_for_identity <identity>: prints the ledger
# file keyed by the sha256 of the identity; returns non-zero when the identity
# is empty, the digest cannot be computed, or HOME is unset.
print_security_review_ledger_path_for_identity() {
  local digest_line ledger_key ledger_dir
  [ -n "$1" ] || return 1
  digest_line=$(printf '%s' "$1" | shasum -a 256) || return 1
  ledger_key="${digest_line%% *}"
  [[ "$ledger_key" =~ ^[0-9a-f]{64}$ ]] || return 1
  ledger_dir=$(print_security_review_ledger_dir) || return 1
  printf '%s/%s.json' "$ledger_dir" "$ledger_key"
}

# print_security_review_ledger_path <directory inside a repository>: prints
# the ledger file for that repository, keyed by its origin's identity; returns
# non-zero when the repository has no origin, when the origin has no
# identity, when the digest cannot be computed, or when HOME is unset.
print_security_review_ledger_path() {
  local repository_identity
  repository_identity=$(print_origin_repository_identity "$1") || return 1
  print_security_review_ledger_path_for_identity "$repository_identity"
}
