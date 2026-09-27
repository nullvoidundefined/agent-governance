#!/usr/bin/env bash
# security-ci-semgrep.sh: the Semgrep step of the reusable security CI
# workflow (.github/workflows/security.yml; IAN-381 Part 7, B-20 and B-21).
# Run it with the working directory inside the repository to scan:
#
#   security-ci-semgrep.sh --mode pr --base <ref>
#   security-ci-semgrep.sh --mode full
#
# The arguments go unchanged to the sibling security-ci-targets.sh, which
# lists the scan targets. Their HEAD content is exported into a scratch
# directory holding an empty .semgrepignore, so neither the repository's own
# ignore file nor Semgrep's default ignore list (tests/, for one) can drop a
# target, and Semgrep runs there with the security rule pack in
# enforce/semgrep/ plus each registry config in SECURITY_CI_REGISTRY_CONFIGS
# (space-separated, default `p/default`), with --disable-nosem so a
# `# nosemgrep` comment cannot silence a finding. Semgrep resolves as
# CLAUDE_SEMGREP_CMD, then `semgrep`, then `uvx semgrep`, the detector's own
# order.
#
# Exits 0 on a clean scan or an empty target list; exits 1 when Semgrep
# reports a finding, printing one GitHub `::error file=<path>,line=<n>`
# annotation per finding; and exits 2, failing CLOSED with the reason on
# stderr, when the lister fails, no Semgrep resolves, Semgrep exits other than
# 0 or 1, its report is not readable JSON, it reports an error at level
# `error`, it reports any error or skipped entry for a code target, or its
# scanned list leaves out a code target. A scan that did not cover what it was
# given is not a clean scan. bash 3.2 compatible.
set -uo pipefail

SECURITY_CI_SEMGREP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_CI_RULES_DIR="$SECURITY_CI_SEMGREP_DIR/semgrep"
# shellcheck source=../hooks/security-surface.sh
. "$SECURITY_CI_SEMGREP_DIR/../hooks/security-surface.sh"

# exit_with_failure <message>: reports a scan that cannot be trusted and exits 2.
exit_with_failure() {
  printf 'security-ci-semgrep: %s; failing closed.\n' "$1" >&2
  exit 2
}

# export_targets <scan dir> <target>...: writes each target's HEAD content
# under <scan dir> in one git process, plus an empty .semgrepignore. Returns
# non-zero when git cannot export them.
export_targets() {
  local scan_dir="$1"
  shift
  git --literal-pathspecs archive --format=tar HEAD -- "$@" | tar -x -C "$scan_dir" || return 1
  : > "$scan_dir/.semgrepignore"
}

# run_semgrep <semgrep command> <scan dir> <report file> <target>...: runs the
# scan and leaves its JSON report in <report file>. Returns Semgrep's exit
# status.
run_semgrep() {
  local semgrep_command="$1" scan_dir="$2" report_file="$3" registry_config
  local config_arguments=(--config "$SECURITY_CI_RULES_DIR")
  shift 3
  for registry_config in ${SECURITY_CI_REGISTRY_CONFIGS-p/default}; do
    config_arguments+=(--config "$registry_config")
  done
  # shellcheck disable=SC2086  # the command may be the two-word `uvx semgrep`
  (cd "$scan_dir" && $semgrep_command "${config_arguments[@]}" --json --error --disable-nosem \
    --metrics=off --disable-version-check --max-target-bytes=0 --quiet "$@") > "$report_file"
}

# list_untrusted_scan_entries <report file> <target list>: prints one line per
# reason the report cannot be trusted: an error at level `error`, an error or
# skipped entry naming a code target, or a code target missing from the
# scanned list. Returns non-zero when the report cannot be read.
list_untrusted_scan_entries() {
  local report_file="$1" target_list="$2"
  printf '%s\n' "$target_list" | jq -r -R -s --slurpfile report "$report_file" --arg code "$SECURITY_SURFACE_CODE_FILE_PATTERN" '
    ($report[0]) as $r
    | [split("\n")[] | select(length > 0 and test($code))] as $code_targets
    | (($r.errors // [])[] | select(.level == "error" or (((.path // .spans[0].file // "") | test($code))))
        | "error: \(.path // .spans[0].file // "<no path>"): \(.message // "" | tostring | .[0:300])"),
      (($r.paths.skipped // [])[] | select((.path // "") | test($code)) | "skipped: \(.path): \(.reason // "")"),
      ($code_targets - ($r.paths.scanned // []) | .[] | "unscanned: \(.)")'
}

# print_finding_annotations <report file>: prints one GitHub error annotation
# per finding. A PR author controls file names, so every value is escaped the
# way GitHub's workflow-command parser expects (`%`, CR, and LF everywhere,
# plus `:` and `,` inside properties), and a crafted name cannot start a
# workflow command of its own. Returns non-zero when the report cannot be read.
print_finding_annotations() {
  jq -r '
    def escape_data: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
    def escape_property: escape_data | gsub(":"; "%3A") | gsub(","; "%2C");
    .results[]
    | "::error file=\(.path | escape_property),line=\(.start.line | escape_property),title=\(.check_id | split(".") | last | escape_property)::\(.extra.message // "" | escape_data)"' "$1"
}

# main: lists the targets, scans them, and exits with the verdict.
main() {
  local target_list semgrep_command scan_dir report_file semgrep_status untrusted_entries finding_count
  local targets=()
  target_list=$(bash "$SECURITY_CI_SEMGREP_DIR/security-ci-targets.sh" "$@") \
    || exit_with_failure "the scan-target lister failed"
  if [ -z "$target_list" ]; then
    echo "security-ci-semgrep: no scan targets; nothing to scan."
    exit 0
  fi
  while IFS= read -r target_path; do
    [ -n "$target_path" ] && targets+=("$target_path")
  done <<< "$target_list"
  semgrep_command=$(resolve_security_surface_semgrep_command)
  [ -n "$semgrep_command" ] || exit_with_failure "no Semgrep resolves (tried CLAUDE_SEMGREP_CMD, semgrep, uvx semgrep)"
  scan_dir=$(mktemp -d) || exit_with_failure "could not create a scratch directory"
  report_file=$(mktemp) || exit_with_failure "could not create a report file"
  trap 'rm -rf "$scan_dir" "$report_file"' EXIT
  export_targets "$scan_dir" "${targets[@]}" || exit_with_failure "could not export the targets' HEAD content"
  run_semgrep "$semgrep_command" "$scan_dir" "$report_file" "${targets[@]}"
  semgrep_status=$?
  jq -e '(.results | type == "array") and ((.paths.scanned // []) | type == "array")' "$report_file" >/dev/null 2>&1 \
    || exit_with_failure "Semgrep printed no readable JSON report (exit $semgrep_status)"
  [ "$semgrep_status" -le 1 ] || exit_with_failure "Semgrep crashed (exit $semgrep_status)"
  untrusted_entries=$(list_untrusted_scan_entries "$report_file" "$target_list") \
    || exit_with_failure "could not read Semgrep's error and scanned lists"
  [ -z "$untrusted_entries" ] || exit_with_failure "Semgrep did not fully scan the targets:
$untrusted_entries"
  finding_count=$(jq '.results | length' "$report_file") || exit_with_failure "could not count Semgrep's findings"
  if [ "$finding_count" -eq 0 ]; then
    [ "$semgrep_status" -eq 0 ] || exit_with_failure "Semgrep exited 1 but its report holds no finding"
    echo "security-ci-semgrep: ${#targets[@]} target(s) scanned, no findings."
    exit 0
  fi
  print_finding_annotations "$report_file" || exit_with_failure "could not read Semgrep's findings"
  echo "security-ci-semgrep: $finding_count finding(s); fix each one."
  exit 1
}

main "$@"
