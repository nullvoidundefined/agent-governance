#!/usr/bin/env bash
# security-ci-targets.sh: lists the scan targets for the reusable security CI
# workflow (.github/workflows/security.yml; IAN-381 Part 7, B-18 and B-19).
# Run it with the working directory inside the repository to scan.
#
#   security-ci-targets.sh --mode pr --base <ref>
#     every file the range <merge base of ref and HEAD>..HEAD adds, copies,
#     modifies, or renames into, minus the files a `securitySurfaceExclude`
#     glob in the merge base's .enforce.json covers, so a PR cannot exclude
#     its own files by adding the key.
#   security-ci-targets.sh --mode full
#     every file tracked at HEAD, minus the files a glob in HEAD's
#     .enforce.json covers.
#
# Prints one repository-relative path per line and exits 0. The changed-file
# listing and the exclude reading are the security-surface detector's own
# (hooks/security-surface.sh), so the CI and the merge gate agree on what a PR
# excluded. The detector lists deleted paths too, so only paths that exist at
# HEAD are kept.
#
# Fails CLOSED: exits 2 with a message on stderr and nothing on stdout when
# the arguments are invalid, the base does not resolve to a commit, or git or
# the detector fails, because a listing that failed must never read as an
# empty one and pass the scan. bash 3.2 compatible.
set -uo pipefail

SECURITY_CI_TARGETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/security-surface.sh
. "$SECURITY_CI_TARGETS_DIR/../hooks/security-surface.sh"

# exit_with_failure <message>: reports a listing failure and exits 2.
exit_with_failure() {
  printf 'security-ci-targets: %s; failing closed.\n' "$1" >&2
  exit 2
}

# list_paths_present_at_head <head-oid> <path list>: prints the paths of the
# newline-separated list that exist at <head-oid>, in one git process. git
# answers one line per input line, `<type>` or `<name> missing`, so answers
# and paths are paired by line number; `%(rest)` is not used because it would
# split a path at its first space. Returns non-zero when git fails.
list_paths_present_at_head() {
  local head_oid="$1" path_list="$2" object_types
  object_types=$(printf '%s\n' "$path_list" | sed "s|^|$head_oid:|" \
    | git cat-file --batch-check='%(objecttype)' 2>/dev/null) || return 1
  awk 'NR == FNR { answer[FNR] = $0; next } answer[FNR] !~ / missing$/ { print }' \
    <(printf '%s\n' "$object_types") <(printf '%s\n' "$path_list")
}

# list_pr_targets <repo-top> <base-ref> <head-oid>: prints the PR-mode
# targets. Returns non-zero when the base or the merge base does not resolve,
# or when the detector cannot list the range.
list_pr_targets() {
  local repo_top="$1" base_ref="$2" head_oid="$3" base_oid merge_base_oid changed_files
  base_oid=$(git rev-parse --verify --quiet "$base_ref^{commit}") || return 1
  merge_base_oid=$(git merge-base "$base_oid" "$head_oid") || return 1
  changed_files=$(list_included_changed_files "$repo_top" "$merge_base_oid" "$head_oid") || return 1
  [ -n "$changed_files" ] || return 0
  list_paths_present_at_head "$head_oid" "$changed_files"
}

# list_full_targets <repo-top> <head-oid>: prints the full-mode targets.
# Returns non-zero when git cannot list the tree or scope-match.sh did not
# load.
list_full_targets() {
  local repo_top="$1" head_oid="$2" tracked_files file_path
  local exclude_globs=()
  declare -F is_in_scope >/dev/null || return 1
  tracked_files=$(git -c core.quotePath=false ls-tree -r --name-only "$head_oid") || return 1
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && exclude_globs+=("$file_path")
  done < <(read_security_surface_excludes "$repo_top" "$head_oid")
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    if [ "${#exclude_globs[@]}" -gt 0 ] && is_in_scope "$file_path" "${exclude_globs[@]}"; then
      continue
    fi
    printf '%s\n' "$file_path"
  done <<< "$tracked_files"
}

# main: parses the arguments and prints the targets for the chosen mode, or
# fails closed.
main() {
  local scan_mode="" base_ref="" repo_top head_oid target_list
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) scan_mode="${2:-}"; shift 2 || exit_with_failure "--mode needs a value" ;;
      --base) base_ref="${2:-}"; shift 2 || exit_with_failure "--base needs a value" ;;
      *) exit_with_failure "unknown argument '$1'" ;;
    esac
  done
  repo_top=$(git rev-parse --show-toplevel 2>/dev/null) || exit_with_failure "not inside a git work tree"
  head_oid=$(git rev-parse --verify --quiet 'HEAD^{commit}') || exit_with_failure "HEAD does not resolve to a commit"
  case "$scan_mode" in
    pr)
      [ -n "$base_ref" ] || exit_with_failure "--mode pr needs --base <ref>"
      target_list=$(list_pr_targets "$repo_top" "$base_ref" "$head_oid") \
        || exit_with_failure "could not list the files changed between '$base_ref' and HEAD"
      ;;
    full)
      target_list=$(list_full_targets "$repo_top" "$head_oid") \
        || exit_with_failure "could not list the files tracked at HEAD"
      ;;
    *) exit_with_failure "--mode must be pr or full, not '$scan_mode'" ;;
  esac
  [ -z "$target_list" ] || printf '%s\n' "$target_list"
}

main "$@"
