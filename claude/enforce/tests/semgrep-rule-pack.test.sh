#!/usr/bin/env bash
# Verifies the security rule pack in enforce/semgrep/ (IAN-381, B-3 to B-5):
# every rule reports a finding carrying its own id on each of its bad samples
# in enforce/tests/testdata/semgrep/, reports nothing on each of its good
# samples, and actually scans every sample it is tested against, so a sample
# in a language the rule does not cover, or a sample that fails to parse,
# cannot pass as a clean scan. Every rule file shipped in enforce/semgrep/
# must also have at least one bad and one good sample.
#
# Every sample ships with an extra `.sample` suffix (e.g.
# `cors-unvalidated-setting_bad.py.sample`) so neither Semgrep nor CodeQL
# reads it as live code in this repository's own CI. This fixture copies each
# sample into a scratch directory under its real extension (the name minus
# `.sample`) before scanning, and reports failures under the sample's real
# on-disk name (with `.sample`).
#
# Semgrep resolves as `semgrep` on PATH, else `uvx semgrep`; with neither the
# fixture fails naming the install command, and it never skips.
#
# Every failure is collected and printed with its rule and sample, and the
# fixture exits nonzero at the end if any assertion failed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
RULES_DIR="$CLAUDE_HARNESS_ROOT/enforce/semgrep"
SAMPLES_DIR="$CLAUDE_HARNESS_ROOT/enforce/tests/testdata/semgrep"
RULE_IDS="cors-unvalidated-setting cors-literal-wildcard cookie-samesite-none-insecure tls-verification-disabled bcrypt-weak-cost"

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

if command -v semgrep >/dev/null 2>&1; then
  SEMGREP="semgrep"
elif command -v uvx >/dev/null 2>&1; then
  SEMGREP="uvx semgrep"
else
  echo "FAIL: semgrep is not installed and uvx is not available to run it; install one (brew install semgrep, or install uv for uvx semgrep)"
  echo "semgrep-rule-pack.test.sh FAIL"
  exit 1
fi

scan_dir=$(mktemp -d)
src_dir="$scan_dir/src"
mkdir -p "$src_dir"
trap 'rm -rf "$scan_dir"' EXIT

# Copies a sample (named `<...>.sample`) into $src_dir under its real
# extension, so Semgrep infers the language from the name it actually scans.
# Prints the copy's path.
stage_sample() {
  local sample="$1"
  local real_name
  real_name=$(basename "$sample" .sample)
  local dest="$src_dir/$real_name"
  cp "$sample" "$dest"
  echo "$dest"
}

# Runs one rule file over the given samples and leaves the JSON report in
# $scan_dir/<rule>.json. Returns nonzero when Semgrep crashed or printed no
# parseable report, because a crashed scan is not a clean scan.
run_rule() {
  local rule="$1"; shift
  local report="$scan_dir/$rule.json"
  $SEMGREP --config "$RULES_DIR/$rule.yml" --json --quiet --metrics=off "$@" >"$report" 2>"$scan_dir/$rule.err"
  local status=$?
  if [ "$status" -ge 2 ] || ! jq -e '.results | type == "array"' "$report" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Prints the number of results in the report for the sample, counting only
# results whose check_id is the rule id itself or ends in ".<rule id>" (a
# local config file prefixes the id with its dotted directory path).
count_results() {
  local report="$1" sample="$2" rule="${3:-}"
  jq --arg path "$sample" --arg rule "$rule" '
    [.results[] | select(.path == $path)
      | select($rule == "" or .check_id == $rule or (.check_id | endswith("." + $rule)))]
    | length' "$report"
}

# Asserts the sample was scanned and produced no Semgrep error.
check_scanned() {
  local report="$1" sample="$2" rule="$3" name="$4"
  if ! jq -e --arg path "$sample" '(.paths.scanned // []) | index($path) != null' "$report" >/dev/null; then
    report_failure "$rule: $name was not scanned (the rule does not cover its language, or Semgrep skipped it)"
  fi
  if jq -e --arg path "$sample" '[.errors[]? | select((.path // "") == $path)] | length > 0' "$report" >/dev/null; then
    report_failure "$rule: Semgrep reported an error on $name: $(jq -c --arg path "$sample" '[.errors[] | select((.path // "") == $path) | .message] | first' "$report")"
  fi
}

for rule in $RULE_IDS; do
  rule_file="$RULES_DIR/$rule.yml"
  bad_samples=$(ls "$SAMPLES_DIR/${rule}_bad"*.sample 2>/dev/null)
  good_samples=$(ls "$SAMPLES_DIR/${rule}_good"*.sample 2>/dev/null)
  [ -n "$bad_samples" ] || report_failure "$rule: no bad sample in $SAMPLES_DIR"
  [ -n "$good_samples" ] || report_failure "$rule: no good sample in $SAMPLES_DIR"
  if [ ! -f "$rule_file" ]; then
    report_failure "$rule: rule file $rule_file does not exist"
    continue
  fi
  staged_bad=""
  for sample in $bad_samples; do
    staged_bad="$staged_bad $(stage_sample "$sample")"
  done
  staged_good=""
  for sample in $good_samples; do
    staged_good="$staged_good $(stage_sample "$sample")"
  done
  # shellcheck disable=SC2086  # the staged lists are newline/space-separated paths with no spaces
  if ! run_rule "$rule" $staged_bad $staged_good; then
    report_failure "$rule: Semgrep crashed or printed no JSON report: $(head -c 400 "$scan_dir/$rule.err")"
    continue
  fi
  report="$scan_dir/$rule.json"
  for sample in $bad_samples; do
    name=$(basename "$sample")
    staged=$(stage_sample "$sample")
    check_scanned "$report" "$staged" "$rule" "$name"
    if [ "$(count_results "$report" "$staged" "$rule")" -lt 1 ]; then
      report_failure "$rule: bad sample $name produced no finding with check_id $rule"
    fi
  done
  for sample in $good_samples; do
    name=$(basename "$sample")
    staged=$(stage_sample "$sample")
    check_scanned "$report" "$staged" "$rule" "$name"
    found=$(count_results "$report" "$staged")
    if [ "$found" -ne 0 ]; then
      report_failure "$rule: good sample $name produced $found finding(s), expected none"
    fi
  done
done

# A rule file cannot ship without a bad and a good sample.
for rule_file in "$RULES_DIR"/*.yml; do
  [ -f "$rule_file" ] || continue
  rule=$(basename "$rule_file" .yml)
  ls "$SAMPLES_DIR/${rule}_bad"*.sample >/dev/null 2>&1 || report_failure "$rule: rule file has no bad sample in $SAMPLES_DIR"
  ls "$SAMPLES_DIR/${rule}_good"*.sample >/dev/null 2>&1 || report_failure "$rule: rule file has no good sample in $SAMPLES_DIR"
done

# Every sample ships as `<name>.sample`, never under a live code extension
# CI's scanners would read directly, and there are enough of them to cover
# every rule's shapes (a floor, not an exact count, so new samples don't
# break this fixture).
sample_count=0
for sample_path in "$SAMPLES_DIR"/*; do
  [ -f "$sample_path" ] || continue
  sample_count=$((sample_count + 1))
  case "$sample_path" in
    *.sample) ;;
    *) report_failure "testdata: $(basename "$sample_path") does not end in .sample" ;;
  esac
done
[ "$sample_count" -ge 40 ] || report_failure "testdata: expected at least 40 sample files in $SAMPLES_DIR, found $sample_count"

if [ "$failures" -ne 0 ]; then
  echo "semgrep-rule-pack.test.sh FAIL ($failures failure(s))"
  exit 1
fi
echo "semgrep-rule-pack.test.sh PASS"
