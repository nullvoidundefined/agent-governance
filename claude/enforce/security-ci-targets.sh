#!/usr/bin/env bash
# security-ci-targets.sh: lists the scan targets for the reusable security CI
# workflow (.github/workflows/security.yml; IAN-381 Part 7, B-18 and B-19).
# Run it with the working directory inside the repository to scan.
#
#   security-ci-targets.sh --mode pr --base <ref>
#     every file the range <merge base of ref and HEAD>..HEAD adds, copies,
#     or modifies, a rename counting as its new path; the merge base keeps a
#     base branch that moved on from adding its own files to the list.
#   security-ci-targets.sh --mode full
#     every file tracked at HEAD.
#
# Prints one repository-relative path per line and exits 0. No exclude list
# narrows either mode: R-109 scopes `.enforce.json` `securitySurfaceExclude`
# to the security-surface detector and gives the rule pack none, so a path
# can leave the security review's view but never the rule pack's (owner
# decision 2026-09-27).
#
# Fails CLOSED: exits 2 with a message on stderr and nothing on stdout when
# the arguments are invalid, the base does not resolve to a commit, or git
# fails, because a listing that failed must never read as an empty one and
# pass the scan. bash 3.2 compatible.
set -uo pipefail

# exit_with_failure <message>: reports a listing failure and exits 2.
exit_with_failure() {
  printf 'security-ci-targets: %s; failing closed.\n' "$1" >&2
  exit 2
}

# list_pr_targets <base-ref> <head-oid>: prints the PR-mode targets. Returns
# non-zero when the base or the merge base does not resolve, or git cannot
# diff the range.
list_pr_targets() {
  local base_ref="$1" head_oid="$2" base_oid merge_base_oid
  base_oid=$(git rev-parse --verify --quiet "$base_ref^{commit}") || return 1
  merge_base_oid=$(git merge-base "$base_oid" "$head_oid") || return 1
  git -c core.quotePath=false diff --name-only --no-renames --no-ext-diff --diff-filter=ACM \
    "$merge_base_oid" "$head_oid"
}

# list_full_targets <head-oid>: prints every file tracked at <head-oid>.
# Returns non-zero when git cannot list the tree.
list_full_targets() {
  git -c core.quotePath=false ls-tree -r --name-only "$1"
}

# main: parses the arguments and prints the targets for the chosen mode, or
# fails closed.
main() {
  local scan_mode="" base_ref="" head_oid target_list
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) scan_mode="${2:-}"; shift 2 || exit_with_failure "--mode needs a value" ;;
      --base) base_ref="${2:-}"; shift 2 || exit_with_failure "--base needs a value" ;;
      *) exit_with_failure "unknown argument '$1'" ;;
    esac
  done
  git rev-parse --show-toplevel >/dev/null 2>&1 || exit_with_failure "not inside a git work tree"
  head_oid=$(git rev-parse --verify --quiet 'HEAD^{commit}') || exit_with_failure "HEAD does not resolve to a commit"
  case "$scan_mode" in
    pr)
      [ -n "$base_ref" ] || exit_with_failure "--mode pr needs --base <ref>"
      target_list=$(list_pr_targets "$base_ref" "$head_oid") \
        || exit_with_failure "could not list the files changed between '$base_ref' and HEAD"
      ;;
    full)
      target_list=$(list_full_targets "$head_oid") \
        || exit_with_failure "could not list the files tracked at HEAD"
      ;;
    *) exit_with_failure "--mode must be pr or full, not '$scan_mode'" ;;
  esac
  [ -z "$target_list" ] || printf '%s\n' "$target_list"
}

main "$@"
