#!/usr/bin/env bash
# security-ci-targets.sh: lists the scan targets for the reusable security CI
# workflow (.github/workflows/security.yml; IAN-381 Part 7, B-18, B-19, B-25).
# Run it anywhere inside the repository; paths are always repository-relative.
#
#   security-ci-targets.sh --mode pr --base <ref>
#     every file the range <merge base of ref and HEAD>..HEAD changes in any
#     way other than deleting it: added, copied, modified, type-changed (a
#     symlink replaced by a regular file), or renamed into, the new path
#     counting; the merge base keeps a base branch that moved on from adding
#     its own files to the list.
#   security-ci-targets.sh --mode full
#     every file tracked at HEAD.
#
# Prints one repository-relative path per line and exits 0. No exclude list
# narrows either mode: R-109 scopes `.enforce.json` `securitySurfaceExclude`
# to the security-surface detector and gives the rule pack none, so a path
# can leave the security review's view but never the rule pack's (owner
# decision 2026-09-27). Paths are read NUL-separated, so git never quotes
# them, and a name holding a control character (a tab, a newline) is refused
# rather than printed, because a line-based consumer could read it as another
# file's name.
#
# Fails CLOSED: exits 2 with a message on stderr and nothing on stdout when
# the arguments are invalid, the base does not resolve to a commit, git
# fails, or a target's name holds a control character, because a listing that
# failed must never read as an empty one and pass the scan. bash 3.2
# compatible.
set -uo pipefail

# exit_with_failure <message>: reports a listing failure and exits 2.
exit_with_failure() {
  printf 'security-ci-targets: %s; failing closed.\n' "$1" >&2
  exit 2
}

# list_pr_targets <base-ref> <head-oid>: prints the PR-mode targets,
# NUL-separated. Returns non-zero when the base or the merge base does not
# resolve, or git cannot diff the range.
list_pr_targets() {
  local base_ref="$1" head_oid="$2" base_oid merge_base_oid
  base_oid=$(git rev-parse --verify --quiet "$base_ref^{commit}") || return 1
  merge_base_oid=$(git merge-base "$base_oid" "$head_oid") || return 1
  git diff --name-only -z --no-renames --no-ext-diff --diff-filter=d "$merge_base_oid" "$head_oid"
}

# list_full_targets <head-oid>: prints every file tracked at <head-oid>,
# NUL-separated. Returns non-zero when git cannot list the tree.
list_full_targets() {
  git ls-tree -r --name-only -z "$1"
}

# convert_target_names <NUL-separated names file>: prints each name on its
# own line. Returns non-zero, printing nothing, when any name holds a control
# character.
convert_target_names() {
  local names_file="$1" target_path target_lines=""
  while IFS= read -r -d '' target_path; do
    case "$target_path" in
      *[[:cntrl:]]*) return 1 ;;
    esac
    target_lines="$target_lines$target_path"$'\n'
  done < "$names_file"
  printf '%s' "$target_lines"
}

# write_targets <scan mode> <base ref> <head oid> <names file>: writes the
# chosen mode's NUL-separated targets to <names file>, or fails closed.
write_targets() {
  local scan_mode="$1" base_ref="$2" head_oid="$3" names_file="$4"
  case "$scan_mode" in
    pr)
      [ -n "$base_ref" ] || exit_with_failure "--mode pr needs --base <ref>"
      list_pr_targets "$base_ref" "$head_oid" > "$names_file" \
        || exit_with_failure "could not list the files changed between '$base_ref' and HEAD"
      ;;
    full)
      list_full_targets "$head_oid" > "$names_file" \
        || exit_with_failure "could not list the files tracked at HEAD"
      ;;
    *) exit_with_failure "--mode must be pr or full, not '$scan_mode'" ;;
  esac
}

# main: parses the arguments and prints the targets for the chosen mode, or
# fails closed.
main() {
  local scan_mode="" base_ref="" repo_top head_oid names_file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) scan_mode="${2:-}"; shift 2 || exit_with_failure "--mode needs a value" ;;
      --base) base_ref="${2:-}"; shift 2 || exit_with_failure "--base needs a value" ;;
      *) exit_with_failure "unknown argument '$1'" ;;
    esac
  done
  repo_top=$(git rev-parse --show-toplevel 2>/dev/null) || exit_with_failure "not inside a git work tree"
  cd "$repo_top" || exit_with_failure "could not enter the repository root"
  head_oid=$(git rev-parse --verify --quiet 'HEAD^{commit}') || exit_with_failure "HEAD does not resolve to a commit"
  names_file=$(mktemp) || exit_with_failure "could not create a scratch file"
  # The EXIT trap runs after main's locals are gone, so it carries the path
  # expanded now rather than the variable's name.
  # shellcheck disable=SC2064
  trap "rm -f '$names_file'" EXIT
  write_targets "$scan_mode" "$base_ref" "$head_oid" "$names_file"
  convert_target_names "$names_file" || exit_with_failure "a target's file name holds a control character"
}

main "$@"
