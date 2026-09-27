#!/usr/bin/env bash
# security-ci-semgrep.sh: the Semgrep step of the reusable security CI
# workflow (.github/workflows/security.yml; IAN-381 Part 7, B-20, B-21, and
# B-24 to B-27). Run it anywhere inside the repository to scan:
#
#   security-ci-semgrep.sh --mode pr --base <ref>
#   security-ci-semgrep.sh --mode full
#
# The arguments go unchanged to the sibling security-ci-targets.sh, which
# lists the scan targets. Their HEAD content is exported into a scratch
# directory, every `.semgrepignore` the export carries is deleted and an
# empty one written at its root, and Semgrep runs there with --no-git-ignore,
# so no ignore file a PR supplies, and no default ignore list (tests/, for
# one), can drop a target. The rules are the security rule pack in
# enforce/semgrep/ plus each registry config in SECURITY_CI_REGISTRY_CONFIGS
# (space-separated, default `p/default`), with --disable-nosem so a
# `# nosemgrep` comment cannot silence a finding. The targets follow a `--`,
# so a PR author's file named like an option (`--severity=INFO`) is read as
# a file. Semgrep resolves as CLAUDE_SEMGREP_CMD, then `semgrep`, then
# `uvx semgrep`, the detector's own order.
#
# Exits 0 on a clean scan or an empty target list; exits 1 when Semgrep
# reports a finding, printing one GitHub `::error file=<path>,line=<n>`
# annotation per finding; and exits 2, failing CLOSED with the reason on
# stderr, when the lister fails, no Semgrep resolves, Semgrep exits other than
# 0 or 1, its report is not readable JSON, it reports an error at level
# `error` or any error naming a code target, it skipped any target, or its
# scanned list leaves out a code target. A scan that did not cover what it was
# given is not a clean scan. A PR author controls file names and file
# contents, so every report value this prints, diagnostics included, is
# escaped for GitHub's workflow-command parser, and Semgrep's own stderr is
# captured and, on a failed scan, printed escaped under a fixed prefix rather
# than passed through raw (B-32). bash 3.2 compatible.
set -uo pipefail

SECURITY_CI_SEMGREP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_CI_RULES_DIR="$SECURITY_CI_SEMGREP_DIR/semgrep"
# shellcheck source=../hooks/security-surface.sh
. "$SECURITY_CI_SEMGREP_DIR/../hooks/security-surface.sh"

# The jq definitions that escape a value for GitHub's workflow-command
# parser: `%`, CR, and LF everywhere, plus `:` and `,` inside properties.
SECURITY_CI_JQ_ESCAPES='
  def escape_data: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  def escape_property: escape_data | gsub(":"; "%3A") | gsub(","; "%2C");'

# exit_with_failure <message>: reports a scan that cannot be trusted and exits 2.
exit_with_failure() {
  printf 'security-ci-semgrep: %s; failing closed.\n' "$1" >&2
  exit 2
}

# export_targets <scan dir> <target>...: writes each target's HEAD content
# under <scan dir> in one git process, deletes every `.semgrepignore` the
# export carries, and writes an empty one at the root. Returns non-zero when
# git cannot export them.
export_targets() {
  local scan_dir="$1"
  shift
  git --literal-pathspecs archive --format=tar HEAD -- "$@" | tar -x -C "$scan_dir" || return 1
  find "$scan_dir" -name .semgrepignore -exec rm -f {} + || return 1
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
    --no-git-ignore --metrics=off --disable-version-check --max-target-bytes=0 --quiet -- "$@") \
    > "$report_file" 2> "$report_file.stderr"
}

# print_semgrep_stderr <report file>: prints what Semgrep wrote to stderr, one
# line at a time under a fixed prefix and escaped for the workflow-command
# parser, so an echoed file name or snippet cannot start a command of its own
# (B-32). Prints nothing when Semgrep wrote nothing.
print_semgrep_stderr() {
  local stderr_file="$1.stderr"
  [ -s "$stderr_file" ] || return 0
  jq -R -r '"security-ci-semgrep: semgrep stderr: " + (gsub("%"; "%25") | gsub("\r"; "%0D"))' "$stderr_file" >&2
}

# list_untrusted_scan_entries <report file> <target list>: prints one escaped
# line per reason the report cannot be trusted: an error at level `error`, an
# error naming a code target, any skipped entry, or a code target missing from
# the scanned list. Returns non-zero when the report cannot be read.
list_untrusted_scan_entries() {
  local report_file="$1" target_list="$2"
  printf '%s\n' "$target_list" | jq -r -R -s --slurpfile report "$report_file" --arg code "$SECURITY_SURFACE_CODE_FILE_PATTERN" "$SECURITY_CI_JQ_ESCAPES"'
    ($report[0]) as $r
    | [split("\n")[] | select(length > 0 and test($code))] as $code_targets
    | (($r.errors // [])[] | select(.level == "error" or (((.path // .spans[0].file // "") | test($code))))
        | "error: \(.path // .spans[0].file // "<no path>" | escape_data): \(.message // "" | tostring | .[0:300] | escape_data)"),
      (($r.paths.skipped // [])[] | "skipped: \(.path // "<no path>" | escape_data): \(.reason // "" | escape_data)"),
      ($code_targets - ($r.paths.scanned // []) | .[] | "unscanned: \(escape_data)")'
}

# print_finding_annotations <report file>: prints one GitHub error annotation
# per finding, every value escaped so a crafted file name or message cannot
# start a workflow command of its own. Returns non-zero when the report cannot
# be read.
print_finding_annotations() {
  jq -r "$SECURITY_CI_JQ_ESCAPES"'
    .results[]
    | "::error file=\(.path | escape_property),line=\(.start.line | escape_property),title=\(.check_id | split(".") | last | escape_property)::\(.extra.message // "" | escape_data)"' "$1"
}

# scan_targets <report file> <target>...: resolves Semgrep, exports the
# targets, and scans them, leaving the report in <report file>. Prints
# Semgrep's exit status; fails closed when the scan cannot run.
scan_targets() {
  local report_file="$1" semgrep_command scan_dir
  shift
  semgrep_command=$(resolve_security_surface_semgrep_command)
  [ -n "$semgrep_command" ] || exit_with_failure "no Semgrep resolves (tried CLAUDE_SEMGREP_CMD, semgrep, uvx semgrep)"
  scan_dir=$(mktemp -d) || exit_with_failure "could not create a scratch directory"
  export_targets "$scan_dir" "$@" || { rm -rf "$scan_dir"; exit_with_failure "could not export the targets' HEAD content"; }
  run_semgrep "$semgrep_command" "$scan_dir" "$report_file" "$@"
  printf '%s' "$?"
  rm -rf "$scan_dir"
}

# fail_scan_verdict <report file> <message>: prints Semgrep's escaped stderr,
# then reports a scan that cannot be trusted and exits 2.
fail_scan_verdict() {
  print_semgrep_stderr "$1"
  exit_with_failure "$2"
}

# report_scan_verdict <report file> <semgrep status> <target list>
# <target count>: checks the report can be trusted, prints the verdict, and
# exits 0, 1, or 2.
report_scan_verdict() {
  local report_file="$1" semgrep_status="$2" target_list="$3" target_count="$4" untrusted_entries finding_count
  jq -e '(.results | type == "array") and ((.paths.scanned // []) | type == "array")' "$report_file" >/dev/null 2>&1 \
    || fail_scan_verdict "$report_file" "Semgrep printed no readable JSON report (exit $semgrep_status)"
  [ "$semgrep_status" -le 1 ] || fail_scan_verdict "$report_file" "Semgrep crashed (exit $semgrep_status)"
  untrusted_entries=$(list_untrusted_scan_entries "$report_file" "$target_list") \
    || fail_scan_verdict "$report_file" "could not read Semgrep's error and scanned lists"
  [ -z "$untrusted_entries" ] || fail_scan_verdict "$report_file" "Semgrep did not fully scan the targets:
$untrusted_entries"
  finding_count=$(jq '.results | length' "$report_file") || fail_scan_verdict "$report_file" "could not count Semgrep's findings"
  if [ "$finding_count" -eq 0 ]; then
    [ "$semgrep_status" -eq 0 ] || fail_scan_verdict "$report_file" "Semgrep exited 1 but its report holds no finding"
    echo "security-ci-semgrep: $target_count target(s) scanned, no findings."
    exit 0
  fi
  print_finding_annotations "$report_file" || exit_with_failure "could not read Semgrep's findings"
  echo "security-ci-semgrep: $finding_count finding(s); fix each one."
  exit 1
}

# list_semgrep_targets <target list>: prints the targets Semgrep is handed,
# one per line. A PR's own .semgrepignore is deleted from the export, so it
# is left out; it holds no code to scan.
list_semgrep_targets() {
  local target_path
  while IFS= read -r target_path; do
    case "$target_path" in
      ''|.semgrepignore|*/.semgrepignore) ;;
      *) printf '%s\n' "$target_path" ;;
    esac
  done <<< "$1"
}

# main: lists the targets, scans them, and reports the verdict.
main() {
  local repo_top target_list report_file semgrep_status target_path
  local targets=()
  repo_top=$(git rev-parse --show-toplevel 2>/dev/null) || exit_with_failure "not inside a git work tree"
  cd "$repo_top" || exit_with_failure "could not enter the repository root"
  target_list=$(bash "$SECURITY_CI_SEMGREP_DIR/security-ci-targets.sh" "$@") \
    || exit_with_failure "the scan-target lister failed"
  if [ -z "$target_list" ]; then
    echo "security-ci-semgrep: no scan targets; nothing to scan."
    exit 0
  fi
  while IFS= read -r target_path; do
    targets+=("$target_path")
  done < <(list_semgrep_targets "$target_list")
  if [ "${#targets[@]}" -eq 0 ]; then
    echo "security-ci-semgrep: no scan targets; nothing to scan."
    exit 0
  fi
  report_file=$(mktemp) || exit_with_failure "could not create a report file"
  # shellcheck disable=SC2064  # the trap outlives main's locals
  trap "rm -f '$report_file' '$report_file.stderr'" EXIT
  # scan_targets runs in a subshell, so its fail-closed exit (message already
  # on stderr) has to be carried out of it.
  semgrep_status=$(scan_targets "$report_file" "${targets[@]}") || exit 2
  report_scan_verdict "$report_file" "$semgrep_status" "$target_list" "${#targets[@]}"
}

main "$@"
